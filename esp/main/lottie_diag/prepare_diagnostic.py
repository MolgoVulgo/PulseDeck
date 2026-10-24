#!/usr/bin/env python3
"""Prepare one isolated test_002-4 ESP-IDF build; never builds/flashes/installs."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
from generate_diagnostic import EXPECTED_SHA, shape_catalog

MODES = ('b_full_no_heap', 'b_full_deferred_heap', 'split_reduced',
         'split_full_no_heap', 'b_shape_matrix', 'b_full_stack32', 'espressif_player')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--mode',choices=MODES,required=True)
    parser.add_argument('--shape-case',default='add:0')
    parser.add_argument('--esp-dir',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--work-dir',type=Path,default=Path('/tmp/pulsedeck_lottie_test_002_4'))
    args=parser.parse_args()
    if args.mode=='espressif_player':
        print('MODE espressif_player: EXTERNAL_OR_LIVE, READINESS ONLY; NOT AN ESP-IDF BUILD.')
        print('Native LVGL 9.5 has conflicting lv_lottie_* symbols with esp_lv_lottie_player.')
        print('Need separate approved/isolated project and compatible Espressif ThorVG component.')
        print('Preflight: verify component versions, clean standalone demo, original JSON SHA, 32-KiB task stack.')
        print('Do NOT add dependencies or flash from this diagnostic package without a separate user authorization and a verified integration plan.')
        return 0
    esp=args.esp_dir.resolve()
    sdk=esp/'sdkconfig'
    config=sdk.read_bytes()
    for marker in (b'CONFIG_LV_USE_LOTTIE=y',b'CONFIG_SPIRAM_USE_MALLOC=y'):
        if marker not in config: raise SystemExit(f'baseline sdkconfig missing {marker!r}')
    source=esp/'ui/assets/meteocons/fill/clear-day.json'
    raw=source.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=EXPECTED_SHA:
        raise SystemExit('unexpected Meteocons original SHA256; STOP')
    doc=json.loads(raw)
    if len(doc['layers'])!=2: raise SystemExit('expected exactly two original layers')
    _,catalog=shape_catalog(doc['layers'][1])
    if args.mode=='b_shape_matrix':
        typ,_,digit=args.shape_case.partition(':')
        if typ not in ('add','remove') or not digit.isdigit(): raise SystemExit('shape case must be add:N / remove:N')
        ix=int(digit)
        if (typ=='add' and ix>len(catalog)) or (typ=='remove' and ix>=len(catalog)):
            raise SystemExit('shape-case out of range; inspect catalog output')
    else:
        if args.shape_case!='add:0': raise SystemExit('shape-case only valid in b_shape_matrix')
    work=args.work_dir.resolve()
    label=args.mode+('_'+args.shape_case.replace(':','_') if args.mode=='b_shape_matrix' else '')
    dest=work/label
    dest.mkdir(parents=True,exist_ok=True)
    copy=dest/'sdkconfig'
    if not copy.exists() or copy.read_bytes()!=config: copy.write_bytes(config)
    flags=[f'-DPD_LOTTIE_DIAG_TEST={args.mode}',f'-DPD_LOTTIE_SHAPE_CASE={args.shape_case}']
    cmd=['idf.py','-B',str(dest/'build'),f'-DSDKCONFIG={copy}',*flags,'build']
    print('PROFILE',args.mode,'SHAPE_CASE',args.shape_case)
    print('SOURCE SHA256',EXPECTED_SHA)
    print('sdkconfig copy:',copy,'sha256',hashlib.sha256(config).hexdigest())
    if args.mode=='b_shape_matrix':
        for i,(kind,index,typ,name) in enumerate(catalog):
            print(f'SHAPE_CATALOG [{i}] {kind}[{index}] type={typ} name={name!r}')
        print('add:0 is reduced B; add:N progressively inserts omitted elements; remove:N deletes one element from full B.')
        print('Use a different --shape-case for every independent binary; NEVER reuse a running firmware after a crash.')
    print('RUN_FROM:',esp)
    print('BUILD:',shlex.join(cmd))
    print('FLASH:',shlex.join(['idf.py','-B',str(dest/'build'),'-p','/dev/ttyUSB0','flash']))
    print('MONITOR:',shlex.join(['idf.py','-B',str(dest/'build'),'-p','/dev/ttyUSB0','monitor']))
    print('No dependency installs, source changes, or flash have been done by this preparer.')
    print('On any panic stop Ctrl+], collect useful decoded stacks for BOTH CPUs and associated ELF.')
    print('Stable criterion: at least 160 seconds to cover 2 diagnostic cycles (360/5 = 72 seconds each).')

if __name__=='__main__':main()
