#!/bin/bash
# Harmless process/lock calibration: no builds, services, privilege or live HOME.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export KIT_DIR TMP
python3 - <<'PY'
import importlib.util, os, signal, subprocess, sys, time
from pathlib import Path
script = Path(os.environ['KIT_DIR'])/'components/heavy-job.py'
assert script.exists(), 'heavy-job guard missing: concurrent builds are still unguarded'
spec = importlib.util.spec_from_file_location('heavy', script)
heavy = importlib.util.module_from_spec(spec); spec.loader.exec_module(heavy)
root = Path(os.environ['TMP'])
def wait_for(predicate, label):
    end = time.monotonic()+5
    while time.monotonic()<end:
        if predicate(): return
        time.sleep(.02)
    raise AssertionError(label)
owner = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], stdin=subprocess.DEVNULL)
guards=[]
try:
    command = [sys.executable,'-c', 'import os,sys,time; open(sys.argv[1],"w").write(str(os.getpid())); time.sleep(30)', str(root/'child')]
    first = subprocess.Popen([sys.executable,str(script),'--guard',str(owner.pid),str(root/'lock'),*command], stdin=subprocess.DEVNULL)
    guards.append(first)
    wait_for(lambda:(root/'child').exists(), 'first job never started')
    second = subprocess.Popen([sys.executable,str(script),'--guard',str(owner.pid),str(root/'lock'),sys.executable,'-c',f'open({str(root/"second")!r},"w").write("ran")'], stdin=subprocess.DEVNULL)
    guards.append(second); time.sleep(.15)
    assert not (root/'second').exists(), 'parallel heavy jobs escaped the shared lock'
    print('ok: heavy jobs serialize')
    child = int((root/'child').read_text())
    owner.kill(); owner.wait()
    for guard in guards: guard.wait(timeout=5)
    assert not Path(f'/proc/{child}').exists(), 'owner death leaked the heavy child'
    assert not (root/'second').exists(), 'queued work ran after its owner died'
    print('ok: SIGKILL of owner ends active work and abandons queued work')
    # A fresh owner must acquire the lock after that abrupt stop.
    result=heavy.guard(os.getpid(),str(root/'lock'),[sys.executable,'-c','raise SystemExit(7)'])
    assert result==7, 'guard lost command exit code or leaked its lock'
    print('ok: lock freed and command failure propagated')
    plan=heavy.launch_command(['true'], 'test-unit', 'lock', 8192)
    assert '--user' in plan and '--wait' in plan and '--pipe' in plan
    owners=plan[plan.index('--guard')+1].split(',')
    assert str(os.getpid()) in owners and str(os.getppid()) in owners, 'launch must bind wrapper and calling process, not leave an orphan wrapper'
    for prop in ['OOMPolicy=kill','KillMode=control-group','OOMScoreAdjust=800','Nice=10','MemoryMax=6144M']:
        assert f'--property={prop}' in plan, f'missing containment: {prop}'
    print('ok: transient service bounds the job and leaves control services outside it')
    stopped_owner = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], stdin=subprocess.DEVNULL)
    stopped_guard = None
    try:
        stopped_guard = subprocess.Popen([sys.executable,str(script),'--guard',str(stopped_owner.pid),str(root/'lock'),sys.executable,'-c',f'import os,time; open({str(root/"stopped-child")!r},"w").write(str(os.getpid())); time.sleep(30)'], stdin=subprocess.DEVNULL)
        wait_for(lambda:(root/'stopped-child').exists(), 'stopped-owner job never started')
        stopped_child = int((root/'stopped-child').read_text())
        stopped_owner.send_signal(signal.SIGSTOP)
        assert stopped_guard.wait(timeout=5)==125, 'a stopped owner retained the queue'
        assert not Path(f'/proc/{stopped_child}').exists(), 'stopped owner leaked its job'
        print('ok: stopped owners cannot retain the heavy-job queue')
    finally:
        stopped_owner.kill(); stopped_owner.wait()
        if stopped_guard is not None and stopped_guard.poll() is None:
            stopped_guard.terminate(); stopped_guard.wait(timeout=5)
    wrapper = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], stdin=subprocess.DEVNULL)
    caller = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'], stdin=subprocess.DEVNULL)
    joint_guard = None
    try:
        joint_guard = subprocess.Popen([sys.executable,str(script),'--guard',f'{wrapper.pid},{caller.pid}',str(root/'lock'),sys.executable,'-c',f'import os,time; open({str(root/"joint-child")!r},"w").write(str(os.getpid())); time.sleep(30)'], stdin=subprocess.DEVNULL)
        wait_for(lambda:(root/'joint-child').exists(), 'joint-owner job never started')
        joint_child = int((root/'joint-child').read_text())
        caller.kill(); caller.wait()
        assert joint_guard.wait(timeout=5)==125, 'orphan wrapper retained work after its caller died'
        assert wrapper.poll() is None and not Path(f'/proc/{joint_child}').exists()
        print('ok: caller death cancels even while its orphan wrapper stays alive')
    finally:
        wrapper.kill(); wrapper.wait()
        if caller.poll() is None: caller.kill(); caller.wait()
        if joint_guard is not None and joint_guard.poll() is None:
            joint_guard.terminate(); joint_guard.wait(timeout=5)
finally:
    if owner.poll() is None: owner.kill(); owner.wait()
    for guard in guards:
        if guard.poll() is None: guard.terminate(); guard.wait(timeout=5)
PY
