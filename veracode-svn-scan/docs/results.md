# Results

Where scan results end up, what they look like, and how to work with them.

## Contents

- [Where results go](#where-results-go)
- [Pipeline scan results](#pipeline-scan-results)
- [Policy scan results](#policy-scan-results)
- [SCA results](#sca-results)
- [Useful jq queries](#useful-jq-queries)
- [Comparing two scans](#comparing-two-scans)
- [Keeping results](#keeping-results)

## Where results go

| Scan | Where | Format |
|---|---|---|
| Pipeline | `veracode-work/results/pipeline-<artifact>.json`, one per artifact | JSON |
| Policy | The Veracode Platform, under the application profile, version `svn-r<revision>` | Platform UI, API, PDF/XML reports |
| SCA | `veracode-work/results/sca.json` and the SCA workspace in the Platform | JSON |

If you used `-w`, replace `veracode-work` with your folder.

**The work folder is deleted at the start of every run.** Copy or archive anything you want to keep before running again.

## Pipeline scan results

Each artifact gets its own file. The exact layout can vary a little between CLI versions, so open one and check, but the main parts are:

```json
{
  "scan_id": "...",
  "scan_status": "SUCCESS",
  "findings": [
    {
      "title": "executeQuery",
      "issue_id": 1001,
      "issue_type": "Improper Neutralization of Special Elements used in an SQL Command ('SQL Injection')",
      "severity": 4,
      "cwe_id": "89",
      "files": {
        "source_file": {
          "file": "com/example/myapp/UserDao.java",
          "line": 57,
          "function_name": "findUser"
        }
      }
    }
  ]
}
```

### Severity scale

| Value | Veracode severity |
|---|---|
| 5 | Very High |
| 4 | High |
| 3 | Medium |
| 2 | Low |
| 1 | Very Low |
| 0 | Informational |

### What pipeline results are and aren't

- They're a snapshot of this one scan. Nothing is stored against your application profile.
- They don't know about mitigations or approvals recorded in the Platform, so a flaw your team already signed off on still shows up. Veracode supports a **baseline file** for pipeline scans to filter out known findings. If you want that, add `--baseline-file <file>` to the `veracode static scan` line in the script (check `veracode static scan --help` for the exact flag in your CLI version).

## Policy scan results

Policy scans are stored in the Veracode Platform:

1. Open the application profile (the `-a` name).
2. Find the scan named `svn-r<revision>`.
3. Check the policy status (Pass, Did Not Pass, Conditional Pass) and the findings.

The script's exit code tells you the outcome: `0` passed, `4` didn't pass or the scan failed. For the detail, use the Platform. From there you can mark findings as mitigated, download reports, and see trends across scans.

## SCA results

`sca.json` lists the open-source libraries found, their versions, and known vulnerabilities in them. The same results are uploaded to the SCA workspace in the Platform, which is usually easier to browse and lets you track libraries across apps.

## Useful jq queries

Install `jq` on the agent (`dnf install jq` or `apt install jq`).

**Count findings per file:**

```bash
for f in veracode-work/results/pipeline-*.json; do
  echo "$(basename "$f"): $(jq '.findings | length' "$f")"
done
```

**Count by severity:**

```bash
jq -r '.findings | group_by(.severity) | .[] | "severity \(.[0].severity): \(length)"' \
  veracode-work/results/pipeline-*.json
```

**High and Very High only, with location:**

```bash
jq -r '.findings[] | select(.severity >= 4)
       | "\(.severity)  CWE-\(.cwe_id)  \(.files.source_file.file):\(.files.source_file.line)  \(.issue_type)"' \
  veracode-work/results/pipeline-*.json
```

**As CSV, for a spreadsheet:**

```bash
{
  echo 'severity,cwe,file,line,issue'
  jq -r '.findings[] | [.severity, .cwe_id, .files.source_file.file, .files.source_file.line, .issue_type] | @csv' \
    veracode-work/results/pipeline-*.json
} > findings.csv
```

**Count by CWE (what kinds of flaws you have most of):**

```bash
jq -r '.findings[] | "CWE-\(.cwe_id) \(.issue_type)"' veracode-work/results/pipeline-*.json \
  | sort | uniq -c | sort -rn
```

## Comparing two scans

Useful when you want to know what a set of commits added or fixed. Run the two scans into separate folders:

```bash
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r 18000 -w ./work-old || true
./veracode-svn-scan.sh -u https://svn.example.com/repos/myapp/trunk -r 18342 -w ./work-new || true
```

Then compare by CWE, file and function. Line numbers shift as code changes, so they make a poor key.

```bash
key='.findings[] | "\(.cwe_id)|\(.files.source_file.file)|\(.files.source_file.function_name)"'

jq -r "$key" work-old/results/pipeline-*.json | sort > old.txt
jq -r "$key" work-new/results/pipeline-*.json | sort > new.txt

echo "New findings:";   comm -13 old.txt new.txt
echo "Fixed findings:"; comm -23 old.txt new.txt
```

This is a rough comparison: two flaws of the same type in the same function count as one. For anything formal, use the Platform's scan comparison on policy scans.

## Keeping results

The work folder is wiped on the next run, so decide where results should live:

| Option | How |
|---|---|
| Jenkins build artifacts | `archiveArtifacts artifacts: 'veracode-work/results/*.json'` |
| A dated folder on a server | `cp -r veracode-work/results "/archive/myapp/$(date +%F)-r$REV"` |
| Artifact repository | Upload the JSON to Nexus or Artifactory with the build version |
| The Veracode Platform | Use policy mode. The Platform is the system of record |

For audits, policy scans in the Platform are usually what's asked for. Pipeline JSON is best treated as developer feedback.
