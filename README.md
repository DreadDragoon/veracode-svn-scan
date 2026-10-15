# veracode-svn-scan

Scans code stored in Subversion (SVN) with Veracode.

The Veracode CLI can clone Git repos on its own, but it has no idea how to talk to SVN. This script fills that gap. It exports the code from SVN, packages it with the Veracode autopackager, and then runs whichever scans you ask for: pipeline, policy, SCA, or any mix of them.

## Documentation

| Doc | What's in it |
|---|---|
| This README | Overview, requirements, quick start and full option reference |
| [docs/use-cases.md](docs/use-cases.md) | Step-by-step walkthroughs for real situations: first run, branches, release tags, old revisions, nightly scans, monorepos, batch scanning, gating builds, containers, and more |
| [docs/svn-authentication.md](docs/svn-authentication.md) | Everything about SVN usernames, passwords, certificates and keeping credentials safe |
| [docs/jenkins-cloudbees.md](docs/jenkins-cloudbees.md) | Running the script in CloudBees CI / Jenkins: credentials, job types, scheduling, gating, archiving results |
| [docs/results.md](docs/results.md) | Where results go, what they look like, and how to read them |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common errors and how to fix them |

## Repository layout

```
.
├── veracode-svn-scan.sh        the scan script
├── examples/Jenkinsfile        sample CloudBees CI / Jenkins pipeline
├── docs/                       detailed documentation
├── README.md
├── .gitignore
└── .gitattributes
```

## How it works

```
 SVN repo ──svn export──▶ veracode-work/src
                               │
                     veracode package (autopackager builds the app)
                               │
                               ▼
                      veracode-work/verascan  (WAR / JAR / EAR / ZIP)
                               │
            ┌──────────────────┼───────────────────┐
            ▼                  ▼                   ▼
     Pipeline scan        Policy scan          SCA scan
     (Veracode CLI)    (Java API wrapper)   (SourceClear agent,
                                             runs on the source)
            │                  │                   │
            ▼                  ▼                   ▼
   results/pipeline-*.json  Veracode Platform   results/sca.json
```

Step by step:

1. **Resolve the revision.** Whatever you pass with `-r` (HEAD by default) is turned into a real revision number with `svn info`. That number is logged and used as the policy scan version (`svn-r18342`), so every scan maps to exactly one SVN commit.
2. **Export.** `svn export` pulls a clean copy of the code at that revision. No `.svn` folders, nothing left behind on the SVN server.
3. **Package.** `veracode package` detects the language and build tool, builds the app, and drops the scannable artifacts into `veracode-work/verascan`.
4. **Scan.**
   - **Pipeline scan** (`-m pipeline`): fast, runs each artifact through `veracode static scan`. Results come back as JSON in a few minutes. Nothing is stored against an application profile. Best for branches and day-to-day feedback.
   - **Policy scan** (`-m policy`): a full Upload and Scan against your Veracode application profile, using the Java API wrapper. Slower, but results are stored in the Platform, tracked over time, and checked against your security policy. Best for trunk, releases and compliance.
   - **Both** (`-m both`): runs the pipeline scan first, then the policy scan.
   - **SCA** (`-s`): scans the source tree's open-source dependencies for known vulnerabilities. Can be added to any mode.
5. **Report.** JSON results go to `veracode-work/results`, and the script exits with a code that tells your CI tool what happened.

## Requirements

### On the machine running the script

| Requirement | Needed for | Notes |
|---|---|---|
| Linux or macOS with `bash` 4+ | Everything | Windows works through WSL or Git Bash but isn't tested |
| `curl`, `find` | Everything | |
| `svn` client 1.9 or newer | Exporting | `svn --version` to check. 1.9+ is needed for `--show-item` |
| Veracode CLI | Packaging and pipeline scans | Installed automatically into the current folder if it isn't on the PATH |
| The build toolchain for your app | Packaging | The autopackager does a real build. Java apps need the right JDK and Maven or Gradle, .NET apps need the .NET SDK, and so on |
| Java runtime | Policy scans | Any supported Java version for the wrapper |
| `VeracodeJavaAPI.jar` | Policy scans | The Veracode Java API wrapper. The script does **not** download this one. Get it from Veracode (it's also published to Maven Central) and set `VERACODE_WRAPPER_JAR` |
| Network access to SVN, `*.veracode.com` and (for SCA) `download.sourceclear.com` | Everything | See [troubleshooting](docs/troubleshooting.md#proxies-and-firewalls) for proxies |

### Supported languages

The autopackager handles Java, .NET, JavaScript, Python, Go, Kotlin and React Native. For anything else, see [Unsupported languages](docs/use-cases.md#12-the-language-isnt-supported-by-the-autopackager).

### Veracode access

| What | Needed for | Where to get it |
|---|---|---|
| API ID and key | All scans | Veracode Platform, API credentials. Use an API service account for CI |
| An application profile | Policy scans | Create it in the Veracode Platform first. The script won't create one unless you change `-createprofile` |
| SCA agent token | SCA scans | Veracode Platform, SCA workspace, agents |

## Quick start

```bash
# 1. Get the code
git clone https://github.com/<org>/veracode-svn-scan.git
cd veracode-svn-scan
chmod +x veracode-svn-scan.sh

# 2. Veracode credentials
export VERACODE_API_KEY_ID='your-api-id'
export VERACODE_API_KEY_SECRET='your-api-key'

# 3. SVN credentials (skip if the repo allows anonymous reads)
export SVN_USERNAME='your-svn-user'
export SVN_PASSWORD='your-svn-password'

# 4. Run a pipeline scan of trunk
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk
```

When it finishes, look in `veracode-work/results/` and check the exit code with `echo $?`. A first run is walked through in detail in [use case 1](docs/use-cases.md#1-first-run-on-your-own-machine).

## Usage

```bash
./veracode-svn-scan.sh -u <svn_url> [-a <app_name>] [options]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `-u <url>` | SVN URL to scan. Can be trunk, a branch, a tag, or any subfolder. **Required.** | |
| `-a <name>` | Veracode application profile name, exactly as it appears in the Platform. **Required for `policy` and `both`.** | |
| `-r <rev>` | SVN revision to scan. A number (`18342`), `HEAD`, or a date (`{2026-09-01}`) | `HEAD` |
| `-m <mode>` | `pipeline`, `policy` or `both` | `pipeline` |
| `-s` | Also run an SCA scan | off |
| `-w <dir>` | Work directory. **Deleted and recreated on every run.** | `./veracode-work` |
| `-h` | Show help | |

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `VERACODE_API_KEY_ID` | Always | Veracode API ID |
| `VERACODE_API_KEY_SECRET` | Always | Veracode API key |
| `SVN_USERNAME` | If the repo needs auth | SVN username. See [SVN authentication](docs/svn-authentication.md) |
| `SVN_PASSWORD` | If the repo needs auth | SVN password. Only used when `SVN_USERNAME` is set |
| `VERACODE_WRAPPER_JAR` | Policy scans | Full path to `VeracodeJavaAPI.jar` |
| `SRCCLR_API_TOKEN` | With `-s` | SCA agent token |
| `POLICY_SCAN_TIMEOUT` | No | Minutes to wait for a policy scan to finish. Default `60` |

Keep credentials in your CI secret store or a secrets manager. Never commit them, and never hardcode them in the script or a job definition.

### Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | Everything ran and nothing blocking was found | Nothing |
| `1` | Usage or setup problem: missing flag, credentials, or tool | Read the `[ERROR]` line |
| `2` | Packaging failed or produced no artifacts | See [troubleshooting](docs/troubleshooting.md#packaging-fails) |
| `3` | Pipeline scan found flaws or failed | Check `results/pipeline-*.json` |
| `4` | Policy scan failed or the app didn't pass policy | Check the app profile in the Veracode Platform |
| `5` | SCA scan failed | Check the SCA output in the log |

When more than one scan fails, the later scan's code wins (policy over pipeline). SCA only sets the exit code if nothing else failed. [Gating builds](docs/use-cases.md#14-failing-or-not-failing-the-build) shows how to act on these codes.

## Common commands

```bash
# Pipeline scan of trunk
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk

# Pipeline scan of a feature branch
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/branches/feature-login

# Policy scan of a release tag
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/tags/1.4.0 -a "MyApp" -m policy

# Everything, at a specific revision
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r 18342 -a "MyApp" -m both -s

# Two scans side by side on the same agent
./veracode-svn-scan.sh -u .../app-a/trunk -w ./work-app-a &
./veracode-svn-scan.sh -u .../app-b/trunk -w ./work-app-b &
wait
```

Each of these is explained in full in [docs/use-cases.md](docs/use-cases.md).

## Security notes

- The script uses `svn export`, which only reads from SVN. It never commits, locks or changes anything on the server.
- SVN runs with `--no-auth-cache`, so credentials are not saved on the machine.
- The SVN password and the Veracode API key are passed to their tools as command-line arguments. On a shared machine, other users could see them with `ps` while the script runs. On a dedicated build agent this is usually fine. See [SVN authentication](docs/svn-authentication.md#the-process-list-caveat) for details.
- Packaging runs your app's real build (Maven, Gradle, npm and so on), which can run code from the repo and its dependencies. Only scan code you trust, on an agent you're willing to run that build on. The `--trust` flag on `veracode package` is how the script acknowledges this.

## Moving off SVN later

If the code moves to Git, you don't need this script. The Veracode CLI can clone Git repos itself:

```bash
veracode package --source https://github.com/<org>/myapp --type repo --trust
```

Everything after packaging (pipeline scan, policy scan, SCA) works the same way.
