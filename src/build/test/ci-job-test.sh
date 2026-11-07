#!/usr/bin/env bash
# Offline regression coverage: never invokes a daemon, package registry, model or review API.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
export CI_TEST_BASH="$BASH"
python3 - "$repo_root" <<'PY'
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
helper = repo / 'src/build/ci-job.sh'
bash = os.environ['CI_TEST_BASH']
checks = 0

def check(value, message):
    global checks
    if not value:
        raise AssertionError(message)
    checks += 1
    print('PASS:', message)

# This guard must itself survive -O/PYTHONOPTIMIZE, including a regression in check().
try:
    check(False, 'intentional negative check probe')
except AssertionError:
    pass
else:
    raise RuntimeError('check() accepted a false value; regression checks are disabled')
check(checks == 0, 'failed check raises without being counted as a pass')

with tempfile.TemporaryDirectory(prefix='harness-ci-test-') as temp:
    root = pathlib.Path(temp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    slot = root / 'slot'
    work = slot / '_work'
    work.mkdir(parents=True)
    agent_temp = work / '_temp'
    agent_temp.mkdir()
    endpoint = slot / 'docker.sock'
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(str(endpoint))
    log = root / 'docker.log'
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
               AGENT_WORKFOLDER=str(work), AGENT_TEMPDIRECTORY=str(agent_temp),
               SYSTEM_JOBID='job-one', DOCKER_HOST='unix://' + str(endpoint),
               DOCKER_CONTEXT='', LOCAL_IMAGE='harness-ci:job-one', MOCK_LOG=str(log))
    env.pop('CI_JOB_DIR', None)

    def stub(name, body):
        path = bin_dir / name
        path.write_text('#!' + bash + '\nset -euo pipefail\n' + body + '\n')
        path.chmod(0o755)

    stub('uname', "printf '%s\\n' Linux")
    stub('git', 'exit 0')
    stub('az', 'exit 0')
    stub('shellcheck', 'exit 0')
    stub('jq', 'exit 0')
    stub('docker', '''printf '%s\\n' "$*" >> "$MOCK_LOG"
case "$1 $2" in
 'info --format') exit "${MOCK_DOCKER_INFO_FAIL:-0}" ;;
 'image inspect')
   case "${@: -1}" in
     *:foreign) echo sha256:other ;;
     *:missing) exit 1 ;;
     *) echo sha256:owned ;;
   esac ;;
 'image rm') exit "${MOCK_DOCKER_RM_FAIL:-0}" ;;
 *) exit 90 ;;
esac''')

    def run(*args, overrides=None):
        e = dict(env)
        e.update(overrides or {})
        return subprocess.run([bash, str(helper), *args], env=e, text=True, capture_output=True)

    def prepare(kind='build'):
        r = run('prepare', kind)
        check(r.returncode == 0, kind + ' preflight succeeds with isolated prerequisites: ' + r.stderr.strip())
        return pathlib.Path(r.stdout.split('variable=ciJobDir]', 1)[1].strip())

    result = run('prepare', 'build', overrides={'MOCK_DOCKER_INFO_FAIL': '1'})
    check(result.returncode != 0 and 'variable=ciJobDir]' not in result.stdout and not list(agent_temp.iterdir()), 'unreachable Docker fails before creating job state')
    first = prepare()
    second = prepare('review')
    check(first != second, 'concurrent jobs get unique state paths')
    check(first.stat().st_mode & 0o777 == 0o700, 'job state directory is private')
    check((first / '.docker-host').read_text().strip() == env['DOCKER_HOST'], 'private endpoint is recorded unchanged')
    check((second / 'claude').is_dir() and (second / 'npm-cache').is_dir(), 'review CLI config and npm cache are job-local')
    for overrides, message in [
        ({'DOCKER_HOST': ''}, 'missing endpoint fails closed'),
        ({'DOCKER_HOST': 'unix:///var/run/docker.sock'}, 'system endpoint fails closed'),
        ({'DOCKER_CONTEXT': 'shared'}, 'Docker context override fails closed'),
        ({'DOCKER_HOST': 'unix://' + str(root / 'outside.sock')}, 'foreign slot fails closed'),
        ({'DOCKER_HOST': 'unix://' + str(first / '.job-id')}, 'regular file is not accepted as socket'),
    ]:
        before = log.read_text()
        result = run('prepare', 'build', overrides=overrides)
        check(result.returncode != 0, message)
        check(log.read_text() == before, message + ' before Docker invocation')
    before = log.read_text()
    result = run('cleanup-image', overrides={'CI_JOB_DIR': '$(ciJobDir)', 'DOCKER_HOST': ''})
    check(result.returncode == 0 and log.read_text() == before, 'cleanup after failed prepare never invokes Docker')
    result = run('cleanup', overrides={'CI_JOB_DIR': '$(ciJobDir)'})
    check(result.returncode == 0, 'temporary cleanup after failed prepare is a no-op')

    refs = ['registry.example/harness:owned', 'registry.example/harness:foreign', 'registry.example/harness:missing']
    (first / 'published-image-refs').write_text('\n'.join(refs) + '\n')
    result = run('cleanup-image', overrides={'CI_JOB_DIR': str(first)})
    check(result.returncode == 0, 'owned image cleanup succeeds')
    removed = [x[len('image rm '):] for x in log.read_text().splitlines() if x.startswith('image rm ')]
    check(removed == [refs[0], 'harness-ci:job-one'], 'cleanup removes only recorded refs still pointing to this image')
    result = run('cleanup-image', overrides={'CI_JOB_DIR': str(first), 'MOCK_DOCKER_RM_FAIL': '1'})
    check(result.returncode != 0, 'image removal failure is reported rather than hidden')
    before = log.read_text()
    result = run('cleanup-image', overrides={'CI_JOB_DIR': str(first), 'DOCKER_HOST': 'unix:///run/docker.sock'})
    check(result.returncode != 0 and log.read_text() == before, 'cleanup rejects an endpoint changed after preflight')
    result = run('cleanup', overrides={'CI_JOB_DIR': str(first), 'SYSTEM_JOBID': 'other-job'})
    check(result.returncode != 0 and first.exists(), 'cleanup refuses another job ownership marker')
    result = run('cleanup', overrides={'CI_JOB_DIR': str(root)})
    check(result.returncode != 0 and root.exists(), 'cleanup refuses paths outside job state')
    link = agent_temp / 'harness-ci.symlink'
    link.symlink_to(second, target_is_directory=True)
    result = run('cleanup', overrides={'CI_JOB_DIR': str(link)})
    check(result.returncode != 0 and second.exists(), 'cleanup refuses a symlink to another job directory')

    nested = first / 'nested'
    outside = work / 'outside-job'
    empty_suffix = agent_temp / 'harness-ci.'
    for target in [nested, outside, empty_suffix]:
        target.mkdir()
        (target / '.job-id').write_text(env['SYSTEM_JOBID'] + '\n')
        (target / '.docker-host').write_text(env['DOCKER_HOST'] + '\n')
    # Matching markers must not permit nested, traversing or aliased paths.
    invalid_paths = [
        (str(nested), nested, 'nested child'),
        (str(first) + '/../' + second.name, second, 'traversal to a sibling'),
        (str(first) + '/../../outside-job', outside, 'traversal outside agent temp'),
        (str(first) + '/.', first, 'dot path component'),
        (str(first) + '/', first, 'trailing slash'),
        (str(link) + '/', second, 'symlink with trailing slash'),
        (str(empty_suffix), empty_suffix, 'empty job-name suffix'),
    ]
    for invalid, target, label in invalid_paths:
        for command in ['cleanup-image', 'cleanup']:
            before = log.read_text()
            result = run(command, overrides={'CI_JOB_DIR': invalid})
            check(result.returncode != 0 and target.is_dir() and log.read_text() == before,
                  command + ' refuses ' + label + ' without touching state or Docker')

    result = run('cleanup', overrides={'CI_JOB_DIR': str(first)})
    check(result.returncode == 0 and not first.exists() and second.exists(), 'cleanup leaves sibling job state intact')

    stub('node', 'echo 24')
    check(run('check-node').returncode != 0, 'preinstalled Node24 is rejected')
    stub('node', 'echo 20')
    check(run('check-node').returncode == 0, 'selected Node20 is accepted')
    sock.close()

# Check the shipped YAML contract without adding a YAML-parser dependency to CI.
build = (repo / 'azure-pipelines.yml').read_text()
review = (repo / 'claude-pr-review-pipeline.yml').read_text()
def has_static_linux_demands(text, expected_pools):
    # Agent admission does not expand a whole-demand macro. Inspect every pool block.
    lines = text.splitlines()
    demands = []
    for i, line in enumerate(lines):
        if line.strip() != 'demands:':
            continue
        indent = len(line) - len(line.lstrip())
        values = []
        for child in lines[i + 1:]:
            if not child.strip() or child.lstrip().startswith('#'):
                continue
            if len(child) - len(child.lstrip()) <= indent:
                break
            if not child.strip().startswith('- '):
                return False
            values.append(child.strip()[2:])
        demands.append(values)
    return len(demands) == expected_pools and all(values == ['Agent.OS -equals Linux'] for values in demands)

for name, text in [('build', build), ('review', review)]:
    expected_pools = 2 if name == 'build' else 1
    check('vmImage:' not in text and 'name: $(selfHostedPool)' in text, name + ' requires configured self-hosted pool')
    check(has_static_linux_demands(text, expected_pools), name + ' uses only the static Linux admission demand')
    old_runtime_demand = re.sub(r'(?m)^( +)- Agent.OS -equals Linux$',
                               r'\1- Agent.OS -equals Linux\n\1- $(unsupportedDemand)', text)
    check(not has_static_linux_demands(old_runtime_demand, expected_pools), name + ' regression rejects literal whole-demand runtime macros')
    compile_time_demand = old_runtime_demand.replace('$(unsupportedDemand)', '${{ variables.unsupportedDemand }}')
    check(not has_static_linux_demands(compile_time_demand, expected_pools), name + ' rejects unverified compile-time demand variables')
    missing_demand_block = re.sub(r'(?m)^ +demands:\n +- Agent.OS -equals Linux\n', '', text, count=1)
    check(not has_static_linux_demands(missing_demand_block, expected_pools), name + ' rejects a pool with its whole demand block removed')
    check('clean: all' in text and 'clean: true' in text, name + ' cleans persistent workspace and checkout')
check('sudo apt' not in build, 'CI never installs system packages')
check('npm install -g' not in review and '--prefix "$CI_JOB_DIR/cli"' in review, 'review install is job-local')
check("version: '20.x'" in review, 'review retains UseNode20 toolchain')
check('REVIEW_FILE: $(ciJobDir)/review-results.json' in review, 'poster reads the isolated review output')
check('/tmp/pr-diff' not in review and '/tmp/review-results' not in review and '/tmp/claude-stderr' not in review, 'review has no shared temporary filenames')
check("condition: and(always(), eq(variables['reviewResultsReady'], 'true'))" in review, 'artifact skips when Node/npm/review failed before output creation')
check("condition: and(always(), ne(variables['ciJobDir'], ''))" in build, 'Docker cleanup is gated on successful prepare')
check('published-image-refs' in build, 'push records only job-created remote image refs')
check('pr:\n  branches:\n    include:\n      - main' in review and 'trigger: none' in review, 'normal review PR trigger is preserved')

# Exercise the actual inline review script with fake git/Claude, including concurrent state.
match = re.search(r'      - script: \|\n(.*?)        displayName: \'Run Claude Code PR Review\'', review, re.S)
# Select only the nearest preceding script block, not the earlier npm installer.
block = match.group(1).rsplit('      - script: |\n', 1)[-1]
script = '\n'.join(line[10:] if line.startswith('          ') else line for line in block.splitlines())
with tempfile.TemporaryDirectory(prefix='harness-review-test-') as temp:
    root = pathlib.Path(temp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    git = bin_dir / 'git'
    git.write_text('#!' + bash + '\nif [[ "$1" == diff ]]; then printf "%s" "${MOCK_DIFF:-}"; fi\n')
    git.chmod(0o755)
    for i, diff in enumerate(['', 'diff --git a/a b/a\n+changed line\n' * 10]):
        state = root / str(i)
        cli = state / 'cli/node_modules/.bin'
        cli.mkdir(parents=True)
        claude = cli / 'claude'
        claude.write_text('#!' + bash + '\ncat > "$CI_JOB_DIR/model-input"\nprintf "[]\\n"\n')
        claude.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], CI_JOB_DIR=str(state),
                   MOCK_DIFF=diff, MAX_DIFF_BYTES='40', TARGET_BRANCH='main')
        r = subprocess.run([bash, '-c', script], env=env, text=True, capture_output=True)
        check(r.returncode == 0 and (state / 'review-results.json').read_text().strip() == '[]', 'shipped review script handles ' + ('empty' if not diff else 'truncated') + ' diff')
        check('variable=reviewResultsReady]true' in r.stdout, 'artifact readiness is set after output exists')
        if diff:
            check(len((state / 'model-input').read_bytes()) == 40, 'diff cap still applies before invoking model')
        else:
            check(not (state / 'model-input').exists(), 'empty diff skips model execution')
    check((root / '0/review-results.json').is_file(), 'second review leaves first job output intact')
    git.write_text('#!' + bash + '\nexit 1\n')
    state = root / 'failed-diff'
    state.mkdir()
    env['CI_JOB_DIR'] = str(state)
    r = subprocess.run([bash, '-c', script], env=env, text=True, capture_output=True)
    check(r.returncode != 0 and 'variable=reviewResultsReady]' not in r.stdout and not (state / 'review-results.json').exists(), 'failed git diff does not mark a nonexistent artifact ready')
print(f'ci-job-test OK ({checks} checks)')
PY
