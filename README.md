# veracode-svn-scan

Scans code stored in Subversion with Veracode.

The Veracode CLI can clone Git repos on its own, but it doesn't know how to talk to SVN. This script fills that gap. It exports the code from SVN, packages it with the Veracode autopackager, and then runs whichever scans you ask for.

## Repository layout

```
.
├── veracode-svn-scan.sh    the scan script
├── examples/Jenkinsfile    sample CloudBees CI / Jenkins pipeline
├── README.md
├── .gitignore
└── .gitattributes
```

## What it does

1. Resolves the SVN revision (HEAD by default) to an actual revision number, so every scan can be traced back to a commit.
2. Runs `svn export` to get a clean source tree with no `.svn` metadata.
3. Runs `veracode package` to build and package the code into scannable artifacts.
4. Runs the scans:
   - **Pipeline scan**: fast feedback, good for PRs and dev branches. Uses the Veracode CLI.
   - **Policy scan**: Upload and Scan against your application profile, so results show up in the Veracode Platform. Uses the Veracode Java API wrapper, because the CLI only does pipeline scans.
   - **SCA scan** (optional): checks open-source dependencies with the SourceClear agent.
5. Writes results to `veracode-work/results` and exits with a code that tells you what happened.

## Requirements

On the machine or build agent running the script:

| Tool | Needed for |
|---|---|
| `bash`, `curl`, `find` | Everything |
| `svn` client | Exporting the code |
| Veracode CLI | Packaging and pipeline scans. The script installs it if it's missing. |
| Build toolchain for your app (JDK, Maven, Gradle, .NET SDK, Node, etc.) | Packaging. The autopackager does a real build. |
| Java runtime + `VeracodeJavaAPI.jar` | Policy scans only |

The autopackager supports Java, .NET, JavaScript, Python, Go, Kotlin and React Native. For anything else, build the artifact yourself and follow Veracode's packaging guidance.

## Setup

1. Copy `veracode-svn-scan.sh` somewhere on the agent and make it executable:

   ```bash
   chmod +x veracode-svn-scan.sh
   ```

2. Get Veracode API credentials (an API service account is best for CI).

3. For policy scans, download the Veracode Java API wrapper and note where the jar lives.

4. For SCA, get an agent token from the Veracode Platform.

## Usage

```bash
./veracode-svn-scan.sh -u <svn_url> [-a <app_name>] [options]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `-u` | SVN URL (trunk, branch or tag). Required. | |
| `-a` | Veracode application profile name. Required for policy mode. | |
| `-r` | SVN revision to scan | `HEAD` |
| `-m` | Scan mode: `pipeline`, `policy` or `both` | `pipeline` |
| `-s` | Also run an SCA scan | off |
| `-w` | Work directory | `./veracode-work` |
| `-h` | Show help | |

### Environment variables

| Variable | Description |
|---|---|
| `VERACODE_API_KEY_ID` | Veracode API ID. Required. |
| `VERACODE_API_KEY_SECRET` | Veracode API key. Required. |
| `SVN_USERNAME` / `SVN_PASSWORD` | SVN credentials, if the repo needs them |
| `VERACODE_WRAPPER_JAR` | Path to `VeracodeJavaAPI.jar`. Required for policy mode. |
| `SRCCLR_API_TOKEN` | SCA agent token. Required with `-s`. |
| `POLICY_SCAN_TIMEOUT` | Minutes to wait for a policy scan to finish. Default 60. |

Keep credentials in your CI secret store. Don't hardcode them in the script or the job definition.

## Examples

Quick pipeline scan of trunk:

```bash
export VERACODE_API_KEY_ID=xxxx
export VERACODE_API_KEY_SECRET=xxxx

./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk
```

Policy scan of a release tag:

```bash
export VERACODE_WRAPPER_JAR=/opt/veracode/VeracodeJavaAPI.jar

./veracode-svn-scan.sh \
  -u https://svn.example.com/repos/myapp/tags/1.4.0 \
  -a "MyApp" \
  -m policy
```

Everything at once, on a specific revision:

```bash
export SRCCLR_API_TOKEN=xxxx

./veracode-svn-scan.sh \
  -u https://svn.example.com/repos/myapp/trunk \
  -r 18342 \
  -a "MyApp" \
  -m both \
  -s
```

## Output

Everything lands under the work directory (`./veracode-work` unless you change it):

```
veracode-work/
├── src/          exported source
├── verascan/     packaged artifacts
└── results/
    ├── pipeline-<artifact>.json
    └── sca.json
```

The work directory is wiped at the start of every run.

Policy scan results live in the Veracode Platform under the application profile. The scan version is set to `svn-r<revision>`, so you can match findings to the exact SVN commit.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All scans ran, nothing blocking |
| 1 | Usage or setup problem (missing flag, credentials, tools) |
| 2 | Packaging failed or produced no artifacts |
| 3 | Pipeline scan found flaws or failed |
| 4 | Policy scan failed or didn't pass policy |
| 5 | SCA scan failed |

If more than one thing fails, the code from the last failing scan wins, except SCA, which only sets the code when nothing else failed.

## Using it in CloudBees CI / Jenkins

A full example is in [`examples/Jenkinsfile`](examples/Jenkinsfile). The short version:

```groovy
pipeline {
  agent { label 'java-build' }

  environment {
    VERACODE_API_KEY_ID     = credentials('veracode-api-id')
    VERACODE_API_KEY_SECRET = credentials('veracode-api-key')
    VERACODE_WRAPPER_JAR    = '/opt/veracode/VeracodeJavaAPI.jar'
  }

  stages {
    stage('Veracode') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'svn-creds',
                         usernameVariable: 'SVN_USERNAME',
                         passwordVariable: 'SVN_PASSWORD')]) {
          sh '''
            MODE=pipeline
            [ "$BRANCH_NAME" = "trunk" ] && MODE=both
            ./veracode-svn-scan.sh \
              -u "https://svn.example.com/repos/myapp/${BRANCH_NAME}" \
              -a "MyApp" \
              -m "$MODE"
          '''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'veracode-work/results/*.json', allowEmptyArchive: true
    }
  }
}
```

A sensible pattern is pipeline scans on every branch and a full policy scan on trunk or release tags only. Policy scans are slower and count against your app profile.

## Troubleshooting

**"svn: E170013: Unable to connect"**
Check the URL and credentials. On a headless agent the script runs SVN with `--non-interactive`, so it won't prompt for a password or a certificate. If the server uses a self-signed cert, accept it once on the agent or add `--trust-server-cert-failures` to `SVN_AUTH` in the script.

**Packaging fails**
Run `veracode package discover ./veracode-work/src` to see what the autopackager detects and whether your toolchain matches. Most failures are a missing or wrong JDK/SDK version on the agent.

**"No artifacts produced"**
The autopackager ran but didn't find anything it could package. Check the language is supported, or build the artifact yourself and point the scan at it.

**`--results-file` not recognized**
The CLI's flags have changed between releases. Check `veracode static scan --help` for your version and update the flag in the script.

**Policy scan says the app doesn't exist**
The script uses `-createprofile false`. Create the profile in the platform first, or change that to `true` in the script.

**Policy scan times out**
Large apps can take a while. Raise `POLICY_SCAN_TIMEOUT`.
