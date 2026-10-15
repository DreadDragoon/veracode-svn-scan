# Running in CloudBees CI / Jenkins

How to wire the script into CloudBees CI or Jenkins, from a single job to a scan of every app.

## Contents

- [Before you start](#before-you-start)
- [Getting the script onto the agent](#getting-the-script-onto-the-agent)
- [Credentials](#credentials)
- [Pattern A: one scanner job, many apps (parameterized)](#pattern-a-one-scanner-job-many-apps-parameterized)
- [Pattern B: scan on every commit to trunk](#pattern-b-scan-on-every-commit-to-trunk)
- [Pattern C: nightly policy scan](#pattern-c-nightly-policy-scan)
- [Pattern D: multibranch (trunk and branches)](#pattern-d-multibranch-trunk-and-branches)
- [Pattern E: add a scan stage to an existing build](#pattern-e-add-a-scan-stage-to-an-existing-build)
- [Triggering from an SVN post-commit hook](#triggering-from-an-svn-post-commit-hook)
- [Archiving and showing results](#archiving-and-showing-results)
- [Gating the build](#gating-the-build)
- [Timeouts and concurrency](#timeouts-and-concurrency)
- [Agent requirements](#agent-requirements)

## Before you start

You'll need:

- An agent (static or pod) with the tools from the [requirements](../README.md#requirements)
- The plugins: **Pipeline**, **Credentials Binding**, and for some patterns **Subversion**, **Lockable Resources** and **Timestamper**
- Credentials for SVN and Veracode (below)

## Getting the script onto the agent

The script lives in GitHub, and your app code lives in SVN. There are three common ways to bring them together.

### Option 1: Check out this repo in the job (simplest)

```groovy
stage('Get scanner') {
  steps {
    dir('scanner') {
      git url: 'https://github.com/<org>/veracode-svn-scan.git', branch: 'main', credentialsId: 'github-creds'
    }
  }
}
// later: sh 'scanner/veracode-svn-scan.sh -u ...'
```

Pin `branch:` to a tag (for example `v1.0.0`) once things are stable, so a change to the script doesn't surprise every pipeline at once.

### Option 2: Bake it into the agent image

Copy the script into the image along with the Veracode CLI and Java wrapper. See [use case 15](use-cases.md#15-running-in-a-container-or-on-an-openshift--kubernetes-agent). Best for pod agents.

### Option 3: Put it in a shared library

If you already have a Jenkins shared library, add the script as a resource and a step that writes it out:

```groovy
// vars/veracodeSvnScan.groovy
def call(Map args) {
  writeFile file: 'veracode-svn-scan.sh', text: libraryResource('veracode-svn-scan.sh')
  sh 'chmod +x veracode-svn-scan.sh'
  def cmd = "./veracode-svn-scan.sh -u '${args.url}' -m '${args.mode ?: 'pipeline'}'"
  if (args.app) { cmd += " -a '${args.app}'" }
  if (args.sca) { cmd += ' -s' }
  return sh(script: cmd, returnStatus: true)
}
```

```groovy
// in a Jenkinsfile
def rc = veracodeSvnScan(url: 'https://svn.example.com/repos/myapp/trunk', app: 'MyApp', mode: 'policy')
```

Teams then call one step instead of copying shell around.

## Credentials

Create these in **Manage Jenkins** > **Credentials** (or at folder level to limit who can use them):

| ID (suggested) | Kind | Holds |
|---|---|---|
| `svn-creds` | Username with password | SVN read-only account |
| `veracode-api-id` | Secret text | Veracode API ID |
| `veracode-api-key` | Secret text | Veracode API key |
| `srcclr-token` | Secret text | SCA agent token (only if you use `-s`) |
| `github-creds` | Username with password or SSH key | Only if this repo is private |

Bind them like this:

```groovy
environment {
  VERACODE_API_KEY_ID     = credentials('veracode-api-id')
  VERACODE_API_KEY_SECRET = credentials('veracode-api-key')
}
...
withCredentials([usernamePassword(credentialsId: 'svn-creds',
                 usernameVariable: 'SVN_USERNAME',
                 passwordVariable: 'SVN_PASSWORD')]) {
  sh './veracode-svn-scan.sh -u ...'
}
```

Always write the `sh` step with **single quotes**. See [SVN authentication](svn-authentication.md#username-and-password-in-jenkins--cloudbees-ci) for why.

## Pattern A: one scanner job, many apps (parameterized)

**Good for:** a central DevOps or AppSec team that scans on request. One job, any SVN URL.

Store this Jenkinsfile in this repo (for example `examples/Jenkinsfile.scanner`) and point a Pipeline job at it with "Pipeline script from SCM" on GitHub.

```groovy
pipeline {
  agent { label 'veracode' }

  parameters {
    string(name: 'SVN_URL',  description: 'SVN URL to scan (trunk, branch, tag or subfolder)')
    string(name: 'APP_NAME', defaultValue: '', description: 'Veracode application profile (needed for policy/both)')
    string(name: 'REVISION', defaultValue: 'HEAD', description: 'SVN revision, HEAD or {YYYY-MM-DD}')
    choice(name: 'MODE', choices: ['pipeline', 'policy', 'both'], description: 'Scan mode')
    booleanParam(name: 'SCA', defaultValue: false, description: 'Also run an SCA scan')
  }

  options {
    timestamps()
    timeout(time: 4, unit: 'HOURS')
    buildDiscarder(logRotator(numToKeepStr: '50'))
  }

  environment {
    VERACODE_API_KEY_ID     = credentials('veracode-api-id')
    VERACODE_API_KEY_SECRET = credentials('veracode-api-key')
  }

  stages {
    stage('Check input') {
      steps {
        script {
          if (!params.SVN_URL?.trim()) { error 'SVN_URL is required' }
          if (params.MODE != 'pipeline' && !params.APP_NAME?.trim()) {
            error 'APP_NAME is required for policy and both modes'
          }
          currentBuild.description = "${params.MODE}: ${params.SVN_URL} @ ${params.REVISION}"
        }
      }
    }

    stage('Scan') {
      steps {
        withCredentials([
          usernamePassword(credentialsId: 'svn-creds', usernameVariable: 'SVN_USERNAME', passwordVariable: 'SVN_PASSWORD'),
          string(credentialsId: 'srcclr-token', variable: 'SRCCLR_API_TOKEN')
        ]) {
          script {
            def args = '-u "$SVN_URL" -r "$REVISION" -m "$MODE"'
            if (params.APP_NAME?.trim()) { args += ' -a "$APP_NAME"' }
            if (params.SCA)              { args += ' -s' }
            env.SCAN_RC = sh(script: "./veracode-svn-scan.sh ${args}", returnStatus: true).toString()
          }
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'veracode-work/results/*.json', allowEmptyArchive: true
      script {
        switch (env.SCAN_RC) {
          case '0': break
          case '3': unstable('Pipeline scan found flaws'); break
          default:  error("Scan failed with exit code ${env.SCAN_RC}")
        }
      }
    }
  }
}
```

Notes:

- Parameters are passed to the shell as environment variables (`$SVN_URL`, `$MODE` and so on), and the Groovy string only stitches together fixed flag names. That keeps the values out of Groovy interpolation.
- `currentBuild.description` shows what each build scanned in the build history, which helps a lot when one job scans many apps.

## Pattern B: scan on every commit to trunk

**Good for:** fast feedback on trunk.

```groovy
pipeline {
  agent { label 'veracode' }

  triggers { pollSCM('H/5 * * * *') }

  options { timestamps(); timeout(time: 1, unit: 'HOURS') }

  environment {
    APP_SVN_URL             = 'https://svn.example.com/repos/myapp/trunk'
    VERACODE_API_KEY_ID     = credentials('veracode-api-id')
    VERACODE_API_KEY_SECRET = credentials('veracode-api-key')
  }

  stages {
    stage('Checkout') {
      steps {
        // Checking out lets Jenkins poll SVN and sets SVN_REVISION
        checkout([$class: 'SubversionSCM',
                  locations: [[remote: env.APP_SVN_URL, credentialsId: 'svn-creds', local: 'app', depthOption: 'empty']]])
      }
    }
    stage('Pipeline scan') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'svn-creds',
                         usernameVariable: 'SVN_USERNAME', passwordVariable: 'SVN_PASSWORD')]) {
          sh './veracode-svn-scan.sh -u "$APP_SVN_URL" -r "$SVN_REVISION" -m pipeline'
        }
      }
    }
  }

  post {
    always { archiveArtifacts artifacts: 'veracode-work/results/*.json', allowEmptyArchive: true }
  }
}
```

The checkout uses `depthOption: 'empty'` so it only fetches the folder itself, not the whole tree. It's there so Jenkins can poll SVN and know the revision. The script does the real export.

Polling every 5 minutes works, but a post-commit hook is faster and lighter on the SVN server. See [below](#triggering-from-an-svn-post-commit-hook).

## Pattern C: nightly policy scan

**Good for:** keeping the Veracode Platform current without scanning every commit.

```groovy
pipeline {
  agent { label 'veracode' }

  triggers { cron('H 2 * * 1-5') }

  options {
    timestamps()
    timeout(time: 6, unit: 'HOURS')
    lock(resource: 'veracode-policy-MyApp')   // no overlapping policy scans of this app
  }

  environment {
    VERACODE_API_KEY_ID     = credentials('veracode-api-id')
    VERACODE_API_KEY_SECRET = credentials('veracode-api-key')
    POLICY_SCAN_TIMEOUT     = '300'
  }

  stages {
    stage('Policy scan') {
      steps {
        withCredentials([
          usernamePassword(credentialsId: 'svn-creds', usernameVariable: 'SVN_USERNAME', passwordVariable: 'SVN_PASSWORD'),
          string(credentialsId: 'srcclr-token', variable: 'SRCCLR_API_TOKEN')
        ]) {
          sh './veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -a "MyApp" -m policy -s'
        }
      }
    }
  }

  post {
    always  { archiveArtifacts artifacts: 'veracode-work/results/*.json', allowEmptyArchive: true }
    failure { mail to: 'devops-team@example.com', subject: "Nightly Veracode scan failed: MyApp", body: "${env.BUILD_URL}" }
  }
}
```

`H 2 * * 1-5` picks a stable minute in the 2 a.m. hour, so all your nightly jobs don't hit Veracode at exactly 2:00.

## Pattern D: multibranch (trunk and branches)

**Good for:** every branch gets scanned automatically, with the right mode for each.

With the Subversion plugin, a Multibranch Pipeline can discover trunk, branches and tags in an SVN repo. Point it at the repo root, set includes to something like `trunk,branches/*`, and put a Jenkinsfile in each branch (or use a Pipeline-as-YAML or library-provided Jenkinsfile).

`examples/Jenkinsfile` in this repo is written for this. The key part:

```groovy
sh '''
  MODE=pipeline
  [ "$BRANCH_NAME" = "trunk" ] && MODE=both
  ./veracode-svn-scan.sh \
    -u "https://svn.example.com/repos/myapp/${BRANCH_NAME}" \
    -a "MyApp" \
    -m "$MODE"
'''
```

Trunk gets a pipeline and policy scan. Every branch gets a pipeline scan only. `$BRANCH_NAME` is the path under the repo root (`trunk`, `branches/feature-login`), which is why it slots straight into the URL.

## Pattern E: add a scan stage to an existing build

**Good for:** teams that already have a Jenkins build for their SVN app and just want a scan step.

Add a stage after the build:

```groovy
stage('Veracode') {
  steps {
    dir('scanner') {
      git url: 'https://github.com/<org>/veracode-svn-scan.git', branch: 'v1.0.0'
    }
    withCredentials([
      usernamePassword(credentialsId: 'svn-creds', usernameVariable: 'SVN_USERNAME', passwordVariable: 'SVN_PASSWORD'),
      string(credentialsId: 'veracode-api-id',  variable: 'VERACODE_API_KEY_ID'),
      string(credentialsId: 'veracode-api-key', variable: 'VERACODE_API_KEY_SECRET')
    ]) {
      sh 'scanner/veracode-svn-scan.sh -u "$SVN_URL" -r "$SVN_REVISION" -w "$WORKSPACE/veracode-work"'
    }
  }
}
```

The script does its own export and build, separate from the job's build. That means the code is built twice, but the scan doesn't depend on how the existing build is set up. Using `$SVN_REVISION` makes sure both builds are of the same commit.

## Triggering from an SVN post-commit hook

Instead of polling, have SVN tell Jenkins when something is committed.

1. In the Jenkins job, enable **Trigger builds remotely** and set a token, or use the Subversion plugin's built-in notify endpoint.
2. On the SVN server, edit `hooks/post-commit` in the repository:

   ```bash
   #!/bin/sh
   REPOS="$1"
   REV="$2"
   UUID=$(svnlook uuid "$REPOS")

   # Subversion plugin endpoint: tells Jenkins which paths changed
   svnlook changed --revision "$REV" "$REPOS" | \
     curl -s --max-time 10 -X POST \
       -H "Content-Type: text/plain;charset=UTF-8" \
       --data-binary @- \
       "https://jenkins.example.com/subversion/${UUID}/notifyCommit?rev=${REV}" \
     > /dev/null 2>&1 &
   ```

3. Make the hook executable. It runs in the background so a slow Jenkins never holds up a commit.

Jenkins then triggers the jobs whose SVN locations include the changed paths. If Jenkins requires authentication for this endpoint, add an API token to the curl call.

## Archiving and showing results

### Keep the JSON with the build

```groovy
post {
  always {
    archiveArtifacts artifacts: 'veracode-work/results/*.json', allowEmptyArchive: true
  }
}
```

### Put a summary in the build description

```groovy
script {
  def summary = sh(script: '''
    for f in veracode-work/results/pipeline-*.json; do
      [ -f "$f" ] || continue
      n=$(jq '.findings | length' "$f")
      echo "$(basename "$f" .json | sed 's/^pipeline-//'): $n findings"
    done
  ''', returnStdout: true).trim()
  if (summary) { currentBuild.description = summary.replace('\n', '<br>') }
}
```

This needs `jq` on the agent. See [results.md](results.md) for more on the JSON.

### Link to the Platform for policy scans

Policy scan results live in the Veracode Platform. Put a link to the app in the build description or a notification so people know where to look.

## Gating the build

The script exits with different codes for different problems (see [Exit codes](../README.md#exit-codes)). In Jenkins:

```groovy
script {
  def rc = sh(script: './veracode-svn-scan.sh -u "$SVN_URL" -a "MyApp" -m both', returnStatus: true)
  switch (rc) {
    case 0: echo 'Clean'; break
    case 3: unstable('Pipeline scan found flaws'); break
    case 4: error('Did not pass Veracode policy'); break
    case 5: unstable('SCA scan failed'); break
    default: error("Scan could not run (exit ${rc})")
  }
}
```

[Use case 14](use-cases.md#14-failing-or-not-failing-the-build) has more options, like failing only on high-severity findings.

## Timeouts and concurrency

| Concern | What to do |
|---|---|
| Policy scans can take hours | Set the job `timeout` longer than `POLICY_SCAN_TIMEOUT` plus build time |
| Veracode rejects a second policy scan of an app while one is running | Use `lock(resource: "veracode-policy-${APP_NAME}")` from the Lockable Resources plugin |
| Two builds on the same agent sharing a workspace | Use `-w "$WORKSPACE/veracode-work"` so each workspace has its own folder |
| Many apps scanned at once hitting Veracode limits | Throttle with the Throttle Concurrent Builds plugin, or stagger cron times |
| A stuck SVN export | `--non-interactive` stops it hanging on a prompt. A job timeout covers network stalls |

## Agent requirements

Label agents that have everything installed (for example `veracode`) and target that label. The agent needs:

- `bash`, `curl`, `find`, `svn` 1.9+
- The build tools your apps need (JDK, Maven, Gradle, .NET SDK, Node and so on)
- Java for policy scans. The script downloads the Java API wrapper the first time and keeps it in `~/.cache/veracode-svn-scan`, so a persistent home directory (or `VERACODE_TOOLS_DIR` on a persistent volume) saves a download per run
- `jq` if you use the result-parsing snippets
- Network access to SVN, `*.veracode.com`, Maven Central (or your proxy of it, for the wrapper download), your artifact repository and (for SCA) `download.sourceclear.com`
- Ideally, the Veracode CLI pre-installed ([use case 16](use-cases.md#16-using-a-pre-installed-or-pinned-veracode-cli))
