# Use cases

Step-by-step walkthroughs for the situations you're most likely to run into. Each one says when to use it, what to run, what happens, and what to watch out for.

All examples use `https://svn.example.com/repos/myapp` as the SVN repo and `MyApp` as the Veracode application profile. Swap in your own.

Unless a section says otherwise, every example assumes the Veracode credentials are already set:

```bash
export VERACODE_API_KEY_ID='your-api-id'
export VERACODE_API_KEY_SECRET='your-api-key'
```

and, if your SVN server needs a login:

```bash
export SVN_USERNAME='your-svn-user'
export SVN_PASSWORD='your-svn-password'
```

## Contents

1. [First run on your own machine](#1-first-run-on-your-own-machine)
2. [Scanning trunk on every commit](#2-scanning-trunk-on-every-commit)
3. [Scanning a feature branch](#3-scanning-a-feature-branch)
4. [Scanning a release tag](#4-scanning-a-release-tag)
5. [Re-scanning an old revision or release](#5-re-scanning-an-old-revision-or-release)
6. [Nightly policy scan](#6-nightly-policy-scan)
7. [The full scan: pipeline, policy and SCA](#7-the-full-scan-pipeline-policy-and-sca)
8. [Only checking open-source dependencies](#8-only-checking-open-source-dependencies)
9. [One app inside a larger SVN repo](#9-one-app-inside-a-larger-svn-repo)
10. [Scanning many apps in a batch](#10-scanning-many-apps-in-a-batch)
11. [Apps that build more than one artifact](#11-apps-that-build-more-than-one-artifact)
12. [The language isn't supported by the autopackager](#12-the-language-isnt-supported-by-the-autopackager)
13. [Running several scans at once on one agent](#13-running-several-scans-at-once-on-one-agent)
14. [Failing or not failing the build](#14-failing-or-not-failing-the-build)
15. [Running in a container or on an OpenShift / Kubernetes agent](#15-running-in-a-container-or-on-an-openshift--kubernetes-agent)
16. [Using a pre-installed or pinned Veracode CLI and Java wrapper](#16-using-a-pre-installed-or-pinned-veracode-cli-and-java-wrapper)
17. [Debugging a scan that went wrong](#17-debugging-a-scan-that-went-wrong)

## Picking a scan mode

If you're not sure which mode to use, start here.

| Situation | Mode | Why |
|---|---|---|
| Developer wants quick feedback on their changes | `pipeline` | Fast, nothing recorded in the Platform |
| Feature or bugfix branch in CI | `pipeline` | Same as above. Branches come and go |
| Trunk, after every merge | `pipeline` | Catch problems early without waiting on a full scan |
| Trunk, once a day | `policy` | Keeps the Platform's view of the app current |
| Release candidate or release tag | `policy` or `both` | You need the policy result for sign-off |
| Audit or compliance evidence | `policy` | Results are stored, versioned and checked against policy |
| Worried about vulnerable libraries | add `-s` | SCA covers open-source dependencies, which static scans don't |

---

## 1. First run on your own machine

**When:** You want to try the script before putting it in a pipeline, or you want to scan something by hand.

### Step 1: Check your tools

```bash
bash --version     # 4 or newer
svn --version      # 1.9 or newer
java -version      # needed for Java apps and for policy scans
mvn -v             # or gradle -v, dotnet --version, node -v, depending on the app
```

You don't need to install the Veracode CLI first. The script installs it into the current folder if it can't find it. (If you'd rather install it yourself, see [use case 16](#16-using-a-pre-installed-or-pinned-veracode-cli-and-java-wrapper).)

### Step 2: Check you can reach the SVN repo

```bash
svn info https://svn.example.com/repos/myapp/trunk
```

If that asks for a password, enter it. If it shows the repo details, you're good. If it complains about a certificate, see [Certificates](svn-authentication.md#self-signed-or-internal-certificates).

### Step 3: Set your credentials

```bash
export VERACODE_API_KEY_ID='your-api-id'
export VERACODE_API_KEY_SECRET='your-api-key'
export SVN_USERNAME='your-svn-user'
export SVN_PASSWORD='your-svn-password'
```

Use single quotes so characters like `$`, `!` and `&` in passwords don't get interpreted by the shell.

If you'd rather not leave the password in your shell history, read it in instead:

```bash
read -rsp 'SVN password: ' SVN_PASSWORD && export SVN_PASSWORD && echo
```

### Step 4: Run a pipeline scan

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk
```

### Step 5: Read the output

A normal run looks something like this:

```
[15:52:01] Scanning https://svn.example.com/repos/myapp/trunk at r18342
[15:52:01] Exporting source
[15:52:09] Packaging with Veracode autopackager
...build output...
[15:54:30] Artifacts: myapp.war
[15:54:30] Pipeline scan: myapp.war
...scan output...
[15:57:12] Done. Results in ./veracode-work/results (exit 0)
```

Then:

```bash
echo $?                               # the exit code
ls veracode-work/results/             # the result files
```

See [results.md](results.md) for how to read the JSON.

### Things to know

- `veracode-work/` is deleted at the start of every run. Copy anything you want to keep.
- The first packaging run can be slow while Maven, Gradle, npm or NuGet downloads dependencies. Later runs are faster if the agent keeps its local cache (`~/.m2`, `~/.gradle`, and so on).

---

## 2. Scanning trunk on every commit

**When:** You want every change that lands on trunk checked, without slowing the team down.

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -m pipeline
```

Pipeline mode is the right fit here. It's quick, and it doesn't fill your application profile with a scan for every commit.

### How to trigger it

- **SVN post-commit hook** that calls your CI job's remote trigger URL.
- **Polling** in Jenkins (`pollSCM('H/5 * * * *')`) on the trunk URL.
- **Jenkins multibranch with the Subversion plugin**, which can discover trunk and branches for you.

See [jenkins-cloudbees.md](jenkins-cloudbees.md) for examples of each.

### Scanning exactly the commit that triggered the job

If several commits land close together, `HEAD` might move between the trigger and the scan. Pass the revision from the trigger instead:

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r "$SVN_REVISION"
```

Jenkins sets `SVN_REVISION` when the job checks out from SVN. In a post-commit hook, the revision is the second argument the hook receives.

---

## 3. Scanning a feature branch

**When:** A developer wants feedback on a branch before it's merged.

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/branches/feature-login
```

Point `-u` at the branch folder. Everything else is the same as trunk.

### Why not a policy scan?

A policy scan records the results against the application profile. If you run them on every branch, the profile ends up with a mix of half-finished work and the real state of the app, which makes reporting confusing. Keep branches on pipeline scans.

If you really do need Platform results for a branch (a long-running release branch, for example), use a **sandbox** in the Veracode Platform. The script doesn't pass a sandbox name today, but the Java wrapper supports `-sandboxname` and `-createsandbox`, and you can add them to the policy scan command in the script.

### Branch layouts

SVN doesn't enforce a layout, so check what your repo uses:

| Layout | Branch URL |
|---|---|
| Standard | `.../myapp/branches/feature-login` |
| Grouped | `.../myapp/branches/features/login` |
| Per-developer | `.../myapp/branches/users/rob/login` |

Run `svn ls https://svn.example.com/repos/myapp/branches` to see what's there.

---

## 4. Scanning a release tag

**When:** You're cutting a release and need the policy result for sign-off.

```bash
./veracode-svn-scan.sh \
  -u https://svn.example.com/repos/myapp/tags/1.4.0 \
  -a "MyApp" \
  -m policy
```

### What happens

1. The tag's last-changed revision is looked up (for example r18342).
2. The code is exported, packaged, and uploaded to the `MyApp` profile as scan version `svn-r18342`.
3. The script waits up to `POLICY_SCAN_TIMEOUT` minutes (60 by default) for the scan to finish.
4. Exit code `0` means the scan finished and the app passed policy. Exit code `4` means it didn't pass, or the scan failed or timed out.

### Before you start

- The `MyApp` profile has to exist in the Veracode Platform, and the name has to match exactly, including case and spaces.
- The first policy scan on a machine downloads the Veracode Java API wrapper from Maven Central and caches it. Later runs reuse it. If your agents can't reach Maven Central, set `VERACODE_WRAPPER_REPO` to your Nexus or Artifactory proxy, or set `VERACODE_WRAPPER_JAR` to a copy you already have.
- Big apps can take a long time to scan. If you hit the timeout, raise it:

  ```bash
  POLICY_SCAN_TIMEOUT=180 ./veracode-svn-scan.sh -u ... -a "MyApp" -m policy
  ```

### Want pipeline results too?

Use `-m both`. The pipeline scan runs first and gives you a quick JSON you can archive with the build, then the policy scan runs.

### Matching the scan to the release

The scan version in the Platform is the SVN revision, not the tag name. To find which scan belongs to which release, note the revision the script logs at the start (`Scanning ... at r18342`), or look it up afterwards:

```bash
svn info --show-item last-changed-revision https://svn.example.com/repos/myapp/tags/1.4.0
```

If you'd rather see the tag name in the Platform, change `-version "svn-r$REV_NUM"` in the script to something like `-version "1.4.0-r$REV_NUM"`.

---

## 5. Re-scanning an old revision or release

**When:** A new vulnerability type was announced, an auditor wants evidence for an older release, or you want to know when a flaw was introduced.

### By revision number

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r 17900
```

### By date

SVN accepts dates in curly braces. This scans trunk as it was at the start of September 1:

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r '{2026-09-01}'
```

Quote the date so the shell leaves the braces alone.

### An old release tag

Tags don't usually change, so `HEAD` of a tag is the release:

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/tags/1.2.0 -a "MyApp" -m policy
```

### Things to watch for

- **The path has to exist at that revision.** If `branches/feature-x` was created at r18000, asking for r17900 fails. Use `svn log --stop-on-copy <url>` to see when a branch was created.
- **Old code may need an old toolchain.** A release from three years ago might need Java 8 or an older Node. If packaging fails, check the build tool versions it expects.
- **Policy scans of old code land in the same profile as current scans.** That changes what the Platform shows as the latest result for the app. For historical digging, pipeline scans or a sandbox are usually a better fit.

### Finding when a flaw appeared

Run pipeline scans across a range of revisions and compare the findings:

```bash
for rev in 17800 17900 18000 18100 18200; do
  ./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r "$rev" -w "./work-r$rev" || true
done
```

The `|| true` keeps the loop going even when a scan finds flaws. Each run has its own work folder, so the results are kept. See [results.md](results.md#comparing-two-scans) for comparing them.

---

## 6. Nightly policy scan

**When:** You want the Veracode Platform to always have a recent view of trunk, without a full scan on every commit.

```bash
./veracode-svn-scan.sh \
  -u https://svn.example.com/repos/myapp/trunk \
  -a "MyApp" \
  -m policy \
  -s
```

Schedule it with your CI tool. In Jenkins:

```groovy
triggers { cron('H 2 * * 1-5') }   // some time between 2:00 and 2:59, weekdays
```

### With plain cron

If you're running it from a server rather than CI, put the credentials in a file only you can read:

```bash
# ~/.veracode-scan.env   (chmod 600)
export VERACODE_API_KEY_ID='...'
export VERACODE_API_KEY_SECRET='...'
export SVN_USERNAME='...'
export SVN_PASSWORD='...'
export SRCCLR_API_TOKEN='...'
```

```cron
# crontab -e
15 2 * * 1-5  . $HOME/.veracode-scan.env && cd /opt/veracode-svn-scan && ./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -a "MyApp" -m policy -s -w /var/tmp/veracode-myapp >> /var/log/veracode-myapp.log 2>&1
```

### Things to know

- Veracode can't start a new policy scan on an app while another one is still running. If a nightly run overlaps a release scan, one of them fails. Space them out, or use a sandbox for one of them.
- If nothing changed on trunk since the last scan, you're scanning the same code twice. That's harmless, but if you want to skip it, compare `svn info --show-item last-changed-revision` with the revision from the previous run before calling the script.

---

## 7. The full scan: pipeline, policy and SCA

**When:** Release sign-off, a security review, or the first time an app is onboarded to Veracode.

```bash
export SRCCLR_API_TOKEN='your-sca-token'

./veracode-svn-scan.sh \
  -u https://svn.example.com/repos/myapp/trunk \
  -a "MyApp" \
  -m both \
  -s
```

### Order of operations

1. Export and package (once).
2. Pipeline scan of each artifact.
3. Policy scan of all the artifacts together.
4. SCA scan of the exported source.

All three scans run even if an earlier one finds problems, so you always get the full picture. The exit code reflects the worst failure (see [Exit codes](../README.md#exit-codes)).

### How long it takes

Roughly: packaging time + a few minutes per artifact for pipeline + anything from 10 minutes to several hours for the policy scan, depending on app size + a few minutes for SCA. Make sure your CI job timeout is longer than the total.

---

## 8. Only checking open-source dependencies

**When:** You only care about vulnerable libraries, not your own code.

The script always packages and runs at least a pipeline or policy scan, so it doesn't have an SCA-only mode. Run the SCA agent on its own instead:

```bash
mkdir -p /tmp/myapp-sca
svn export --non-interactive --username "$SVN_USERNAME" --password "$SVN_PASSWORD" --no-auth-cache \
  https://svn.example.com/repos/myapp/trunk /tmp/myapp-sca/src

export SRCCLR_API_TOKEN='your-sca-token'
curl -sSL https://download.sourceclear.com/ci.sh | sh -s -- scan /tmp/myapp-sca/src
```

The SCA agent still needs the build tool for the project (Maven, Gradle, npm and so on) to resolve dependencies, but it doesn't need a full build.

---

## 9. One app inside a larger SVN repo

**When:** Your SVN repo holds several apps, and you only want to scan one.

SVN lets you export any subfolder, so point `-u` straight at it:

```
https://svn.example.com/repos/platform/
├── trunk/
│   ├── billing-service/
│   ├── customer-portal/
│   └── shared-libs/
```

```bash
./veracode-svn-scan.sh \
  -u https://svn.example.com/repos/platform/trunk/billing-service \
  -a "Billing Service" \
  -m policy
```

### When the app depends on a sibling folder

If `billing-service` builds against `shared-libs` with a relative path (for example a Maven parent POM at `../pom.xml`), exporting only `billing-service` breaks the build. You have two options:

- **Export the parent folder** and let the autopackager find the projects:

  ```bash
  ./veracode-svn-scan.sh -u https://svn.example.com/repos/platform/trunk -a "Platform" -m policy
  ```

  This scans everything under it, which may be more than you want.

- **Install the shared pieces first.** If `shared-libs` is published to your artifact repository (Nexus, Artifactory), the app's build pulls it from there and exporting just `billing-service` works.

### svn:externals

`svn export` follows `svn:externals` by default, so external folders are included in the export. If an external points to a different SVN server, the same credentials are used, and if they don't work there the export fails. Check with:

```bash
svn propget svn:externals -R https://svn.example.com/repos/platform/trunk/billing-service
```

---

## 10. Scanning many apps in a batch

**When:** Onboarding a whole portfolio, or a scheduled sweep of every app.

Create a list of apps. One per line: SVN URL, then the Veracode profile name, separated by a pipe:

```text
# apps.txt
https://svn.example.com/repos/billing/trunk|Billing Service
https://svn.example.com/repos/portal/trunk|Customer Portal
https://svn.example.com/repos/reports/trunk|Reporting
```

Then loop over it:

```bash
#!/usr/bin/env bash
# scan-all.sh
set -u
mkdir -p logs
failed=()

while IFS='|' read -r url app; do
  [[ -z "$url" || "$url" == \#* ]] && continue
  slug=$(echo "$app" | tr ' A-Z' '-a-z')
  echo "=== $app ==="
  if ! ./veracode-svn-scan.sh -u "$url" -a "$app" -m policy -w "./work-$slug" \
       > "logs/$slug.log" 2>&1; then
    failed+=("$app (exit $?)")
  fi
done < apps.txt

echo
echo "Finished. ${#failed[@]} app(s) had problems:"
printf '  %s\n' "${failed[@]}"
```

### Things to know

- Each app gets its own `-w` folder, so results don't overwrite each other.
- Each app gets its own log file, which makes it much easier to see which one failed and why.
- This runs the apps one after another. To run them in parallel, see [use case 13](#13-running-several-scans-at-once-on-one-agent), but keep an eye on the agent's CPU, memory and disk.
- Veracode limits how many scans you can have running at once. If you're onboarding dozens of apps, stagger them.

---

## 11. Apps that build more than one artifact

**When:** A multi-module Maven or Gradle build, a .NET solution with several projects, or an EAR that bundles WARs.

You don't need to do anything special. The autopackager puts every artifact into `veracode-work/verascan`, and then:

- **Pipeline scan** runs once per artifact. You get one result file per artifact: `pipeline-api.jar.json`, `pipeline-web.war.json` and so on.
- **Policy scan** uploads all of them together as a single scan, which is what Veracode wants for a multi-module app.

### Checking what got packaged

```bash
ls -l veracode-work/verascan/
```

If a module you expected is missing, the autopackager didn't recognise it. Run discovery to see what it finds:

```bash
veracode package discover veracode-work/src
```

### Test and tooling modules

If test helpers or build tools are packaged and you don't want them scanned, remove them before the scan, or stop the build from producing them for the scan (a Maven profile, for example). Scanning them is usually harmless, just slower and noisier.

---

## 12. The language isn't supported by the autopackager

**When:** The app is in a language the autopackager doesn't handle, or it needs a custom build the autopackager can't work out.

The script packages with the autopackager and doesn't have a "bring your own artifact" option, so call the Veracode tools directly after building:

```bash
# 1. Export
svn export --non-interactive --username "$SVN_USERNAME" --password "$SVN_PASSWORD" --no-auth-cache \
  https://svn.example.com/repos/legacy-app/trunk ./legacy-src

# 2. Build or package it your way, following Veracode's packaging guidance for the language
cd legacy-src && ./build.sh && cd ..
mkdir -p verascan && cp legacy-src/dist/*.zip verascan/

# 3a. Pipeline scan
veracode static scan verascan/legacy-app.zip

# 3b. Policy scan (if you've run the script before, the wrapper is cached in ~/.cache/veracode-svn-scan)
java -jar "$VERACODE_WRAPPER_JAR" \
  -vid "$VERACODE_API_KEY_ID" -vkey "$VERACODE_API_KEY_SECRET" \
  -action UploadAndScan -appname "Legacy App" -createprofile false \
  -filepath verascan -version "manual-$(date +%Y%m%d)"
```

Veracode publishes packaging guidance for each supported language. Follow it closely: a badly packaged app scans "successfully" but misses code.

---

## 13. Running several scans at once on one agent

**When:** You want to scan several apps or branches in parallel to save time.

Give each run its own work folder with `-w`. Without it, they all use `./veracode-work`, and each run deletes the folder the others are using.

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/app-a/trunk -w ./work-app-a > app-a.log 2>&1 &
./veracode-svn-scan.sh -u https://svn.example.com/repos/app-b/trunk -w ./work-app-b > app-b.log 2>&1 &
./veracode-svn-scan.sh -u https://svn.example.com/repos/app-c/trunk -w ./work-app-c > app-c.log 2>&1 &
wait
```

### Things to watch for

- **Two policy scans of the same app can't run at once.** Veracode rejects the second one. Parallel runs are fine across different apps.
- **Shared build caches.** Parallel Maven builds writing to the same `~/.m2` usually work but occasionally corrupt a download. If you see odd build errors, give each run its own cache (`MAVEN_OPTS="-Dmaven.repo.local=./work-app-a/.m2"`), at the cost of more downloads.
- **Resources.** Each run does a full build. Check the agent has enough CPU, memory and disk for all of them.
- **CLI install race.** If the Veracode CLI isn't installed, every run tries to install it into the same folder at the same moment. Install it once beforehand ([use case 16](#16-using-a-pre-installed-or-pinned-veracode-cli-and-java-wrapper)).

---

## 14. Failing or not failing the build

**When:** You need to decide what a scan result should do to the CI job.

The script's exit code tells you what happened (see [Exit codes](../README.md#exit-codes)). What you do with it is up to you.

### Fail on anything (the default)

Just run the script. Any non-zero exit fails the step.

```bash
./veracode-svn-scan.sh -u ... -m pipeline
```

### Report, but never fail

Good while a team is getting started and still working through the backlog of findings.

```bash
./veracode-svn-scan.sh -u ... -m pipeline || echo "Veracode reported issues, see results"
```

### Fail only on policy, not on pipeline findings

```bash
set +e
./veracode-svn-scan.sh -u ... -a "MyApp" -m both
rc=$?
set -e

case $rc in
  0|3) echo "OK (pipeline findings are informational)" ;;
  *)   echo "Failing build, exit code $rc"; exit $rc ;;
esac
```

Exit code `3` is pipeline only. If the policy scan had also failed, the code would be `4`.

### Fail only on setup or packaging problems

Useful when you want to be sure the scan actually ran, but not block on findings yet.

```bash
set +e
./veracode-svn-scan.sh -u ... -m pipeline
rc=$?
set -e
[[ $rc -eq 1 || $rc -eq 2 ]] && { echo "Scan didn't run properly"; exit $rc; }
exit 0
```

### Fail only on high-severity pipeline findings

The pipeline result JSON includes a severity for each finding (5 is Very High, 4 is High). Check it with `jq`:

```bash
./veracode-svn-scan.sh -u ... -m pipeline || true

high=$(jq '[.findings[] | select(.severity >= 4)] | length' veracode-work/results/pipeline-*.json \
       | awk '{s+=$1} END {print s+0}')
echo "High or Very High findings: $high"
[[ "$high" -gt 0 ]] && exit 1
exit 0
```

See [results.md](results.md) for more on the JSON.

### Jenkins: mark unstable instead of failed

```groovy
script {
  def rc = sh(script: './veracode-svn-scan.sh -u ... -m pipeline', returnStatus: true)
  if (rc == 3)       { unstable('Veracode pipeline scan found flaws') }
  else if (rc != 0)  { error("Veracode scan failed with exit code ${rc}") }
}
```

---

## 15. Running in a container or on an OpenShift / Kubernetes agent

**When:** Your CI agents are pods, or you want a clean, repeatable scan environment.

### Build an image with everything the scan needs

Example for Java apps built with Maven. Adjust the JDK and build tools for your apps.

```dockerfile
# Containerfile
FROM registry.access.redhat.com/ubi9/openjdk-17:latest

USER root
RUN microdnf install -y subversion findutils tar gzip unzip && microdnf clean all

# Veracode CLI
RUN cd /usr/local/bin && curl -fsS https://tools.veracode.com/veracode-cli/install | sh

# Veracode Java API wrapper (download the jar first and put it next to this file)
COPY VeracodeJavaAPI.jar /opt/veracode/VeracodeJavaAPI.jar
ENV VERACODE_WRAPPER_JAR=/opt/veracode/VeracodeJavaAPI.jar

COPY veracode-svn-scan.sh /usr/local/bin/veracode-svn-scan.sh
RUN chmod +x /usr/local/bin/veracode-svn-scan.sh

# Run as an arbitrary non-root user (OpenShift friendly)
RUN mkdir -p /work && chmod 0777 /work
WORKDIR /work
USER 1001
```

```bash
podman build -t veracode-svn-scan:latest .
```

### Run it locally

```bash
podman run --rm \
  -e VERACODE_API_KEY_ID -e VERACODE_API_KEY_SECRET \
  -e SVN_USERNAME -e SVN_PASSWORD \
  -v "$PWD/out:/work/veracode-work:Z" \
  veracode-svn-scan:latest \
  veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk
```

Passing `-e NAME` with no value copies the variable from your shell, so the secrets don't appear on the command line. The `-v` mount gives you the results on the host afterwards.

### Run it as a Jenkins / CloudBees pod agent

```groovy
pipeline {
  agent {
    kubernetes {
      yaml '''
        apiVersion: v1
        kind: Pod
        spec:
          containers:
          - name: scan
            image: registry.example.com/devops/veracode-svn-scan:latest
            command: ["sleep"]
            args: ["infinity"]
            resources:
              requests: { cpu: "1", memory: "2Gi" }
              limits:   { cpu: "2", memory: "4Gi" }
      '''
    }
  }
  stages {
    stage('Veracode') {
      steps {
        container('scan') {
          withCredentials([
            usernamePassword(credentialsId: 'svn-creds', usernameVariable: 'SVN_USERNAME', passwordVariable: 'SVN_PASSWORD'),
            string(credentialsId: 'veracode-api-id',  variable: 'VERACODE_API_KEY_ID'),
            string(credentialsId: 'veracode-api-key', variable: 'VERACODE_API_KEY_SECRET')
          ]) {
            sh 'veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -w "$WORKSPACE/veracode-work"'
          }
        }
      }
    }
  }
}
```

### Things to know

- **Build caches don't survive.** Each pod starts with an empty `~/.m2` or `~/.npm`, so builds download everything every time. Point Maven or npm at an internal mirror, or mount a persistent cache volume.
- **Memory.** Big builds plus the CLI can need several GB. If the pod gets OOM-killed, raise the memory limit.
- **Egress.** The pod needs to reach your SVN server, `*.veracode.com`, your artifact repository and (for SCA) `download.sourceclear.com`. Check your NetworkPolicies and egress proxy.
- **Arbitrary user IDs.** OpenShift runs containers as a random UID. The `chmod 0777 /work` above and writing into `$WORKSPACE` keep that working.

---

## 16. Using a pre-installed or pinned Veracode CLI and Java wrapper

**When:** You want every run to use the same, known CLI version, or your agents can't reach the internet to download it.

The script only installs the CLI if `veracode` isn't already on the PATH. Install it yourself and the script uses yours:

```bash
cd /usr/local/bin
curl -fsS https://tools.veracode.com/veracode-cli/install | sudo sh
veracode version
```

### Why bother

- **Repeatability.** Installing at scan time gets you whatever version is current that day. A CLI update can change flags or behaviour between two runs of the same job.
- **Speed.** No download on every run.
- **Offline or locked-down agents.** If agents can't reach `tools.veracode.com`, install the CLI into the agent image or from an internal mirror.
- **Parallel runs.** Avoids several runs trying to install into the same folder at once ([use case 13](#13-running-several-scans-at-once-on-one-agent)).

Update the CLI on a schedule you control, and test a scan after each update.

### The Java API wrapper

Policy scans need the Veracode Java API wrapper. If `VERACODE_WRAPPER_JAR` isn't set, the script handles it:

1. Looks up the latest release in Maven Central's metadata (or uses `VERACODE_WRAPPER_VERSION` if you set it).
2. Checks the cache folder (`~/.cache/veracode-svn-scan`, or `VERACODE_TOOLS_DIR`) for that version.
3. If it's not there, downloads it, checks it against the `.sha1` file Maven publishes next to it, and saves it to the cache.

The cache is separate from the work folder, so it survives between runs and the download only happens once per version.

**Pin the version in CI.** Without a pin, a new wrapper release changes what your next run uses:

```bash
export VERACODE_WRAPPER_VERSION='<version>'   # a version from Maven Central that you've tested
```

**Use your internal Maven proxy** if agents can't reach Maven Central:

```bash
export VERACODE_WRAPPER_REPO='https://nexus.example.com/repository/maven-central'
```

**Or skip the download entirely** by pointing at a copy you manage:

```bash
export VERACODE_WRAPPER_JAR=/opt/veracode/VeracodeJavaAPI.jar
```

If `VERACODE_WRAPPER_JAR` is set to a path that doesn't exist, the script stops rather than downloading, so a typo doesn't silently pull a different version.

---

## 17. Debugging a scan that went wrong

**When:** Something failed and the log doesn't make it obvious why.

### Keep the work folder

The work folder is only cleared at the start of the next run, so after a failure everything is still there:

```bash
ls -R veracode-work | head -50
```

- `veracode-work/src` is exactly what was exported from SVN.
- `veracode-work/verascan` is whatever packaging produced, if it got that far.
- `veracode-work/results` holds any results written before the failure.

### Re-run one step by hand

Re-running the whole script repeats the export every time. Run just the step that failed instead.

**Packaging, with verbose output:**

```bash
veracode package --source veracode-work/src --output veracode-work/verascan --trust --debug
```

**What the autopackager thinks the project is:**

```bash
veracode package discover veracode-work/src
```

**Pipeline scan of one artifact:**

```bash
veracode static scan veracode-work/verascan/myapp.war
```

**SVN access, on its own:**

```bash
svn info --non-interactive --username "$SVN_USERNAME" --password "$SVN_PASSWORD" --no-auth-cache \
  https://svn.example.com/repos/myapp/trunk
```

### Trace every command the script runs

```bash
bash -x ./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk 2>&1 | tee debug.log
```

**Be careful:** `bash -x` prints every command with its arguments, including the SVN password and the Veracode API key. Don't paste that output into a ticket or chat without scrubbing it first.

For specific error messages, see [troubleshooting.md](troubleshooting.md).
