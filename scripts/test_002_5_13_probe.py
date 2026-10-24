#!/usr/bin/env python3
"""Read-only feasibility probe for two-core isolated ThorVG rendering."""
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
patterns={
 'lottie implementation':'**/lv_lottie.c',
 'ThorVG C API':'**/thorvg_capi.h',
 'ThorVG implementation':'**/thorvg_capi.cpp',
 'LVGL port':'esp/main/lvgl_port.c',
 'test harness':'esp/main/svg_test.c',
}
need=['tvg_engine_init','tvg_swcanvas_create','tvg_swcanvas_set_target','tvg_canvas_push','tvg_canvas_draw','tvg_canvas_sync','tvg_animation_set_frame','tvg_animation_new','lv_obj_invalidate','lv_canvas_set_draw_buf']
print('TEST_002_5_13 READ_ONLY_FEASIBILITY root='+str(root))
for title,pat in patterns.items():
    files=sorted(root.glob(pat))
    files=[x for x in files if x.is_file() and not any(p in ('build','managed_build') for p in x.parts)]
    print(f'\n## {title}: {len(files)} matches')
    for f in files[:8]:
        print('  '+str(f.relative_to(root)))
        try:
            text=f.read_text(encoding='utf-8',errors='replace')
        except OSError as e:
            print('  READ_ERROR '+str(e));continue
        for n,line in enumerate(text.splitlines(),1):
            if any(x in line for x in need) or (title=='lottie implementation' and any(x in line for x in ('lottie_update(', 'anim_exec_cb(', 'tvg_', 'lv_canvas_'))):
                print(f'    L{n}: {line.strip()[:180]}')
if not list(root.glob('**/lv_lottie.c')):
    print('\nINCONCLUSIVE: LVGL dependency source is not present; inspect managed_components in the local build environment.')
print('\nNO CONCURRENCY ENABLED. Do not call existing lv_lottie callbacks concurrently.')
