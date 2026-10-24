#!/usr/bin/env python3
"""Build-only Meteocons layer fixtures from verified original JSON. Never writes assets."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

EXPECTED_SHA = '930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24'


def stable_json(doc):
    return json.dumps(doc, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def selection(source, label):
    doc = copy.deepcopy(source)
    doc['layers'] = [copy.deepcopy(source['layers'][0 if label == 'a' else 1])]
    doc['nm'] = 'PulseDeck diag ' + label
    return doc


def shape_catalog(b_layer):
    """Each entry identifies one omitted shape or nested group item; no generic parsing assumptions."""
    shapes = b_layer.get('shapes', [])
    if not isinstance(shapes, list) or not shapes:
        raise ValueError('layer B needs non-empty shapes list')
    first = shapes[0]
    if first.get('ty') != 'gr' or not isinstance(first.get('it'), list):
        raise ValueError('unexpected layer B layout; group+items expected')
    first_items = first['it']
    geometry_i = next((i for i,v in enumerate(first_items) if v.get('ty') in ('sh','el','rc','sr')), None)
    paint_i = next((i for i,v in enumerate(first_items) if v.get('ty') in ('fl','st','gf','gs')), None)
    transform_i = next((i for i in range(len(first_items)-1,-1,-1) if first_items[i].get('ty') == 'tr'), None)
    base_indices = {x for x in (geometry_i,paint_i,transform_i) if x is not None}
    if not base_indices:
        raise ValueError('no first-group geometry, paint or transform')
    catalog = [('item',i,first_items[i].get('ty','?'),first_items[i].get('nm','')) for i in range(len(first_items)) if i not in base_indices]
    catalog += [('shape',i,shapes[i].get('ty','?'),shapes[i].get('nm','')) for i in range(1,len(shapes))]
    if len(catalog)>64:
        raise ValueError('over 64 optional pieces; revise diagnostic plan')
    return base_indices,catalog


def make_b_matrix(b, variant):
    bases, catalog = shape_catalog(b['layers'][0])
    parts = variant.split(':',1)
    if len(parts)!=2 or parts[0] not in ('add','remove') or not parts[1].isdigit():
        raise ValueError('shape-case must be add:N or remove:N')
    family,number=parts[0],int(parts[1])
    if family=='add' and number>len(catalog):
        raise ValueError(f'add step {number} exceeds catalog length {len(catalog)}')
    if family=='remove' and number>=len(catalog):
        raise ValueError(f'remove index {number} exceeds catalog length {len(catalog)}')
    current=copy.deepcopy(b)
    layer=current['layers'][0]
    original_first=b['layers'][0]['shapes'][0]
    if family=='add':
        selected=set(bases)
        for kind,idx,*_ in catalog[:number]:
            if kind=='item': selected.add(idx)
        first=copy.deepcopy(original_first)
        first['it']=[copy.deepcopy(x) for i,x in enumerate(original_first['it']) if i in selected]
        result_shapes=[first]
        chosen_top={idx for kind,idx,*_ in catalog[:number] if kind=='shape'}
        result_shapes += [copy.deepcopy(x) for i,x in enumerate(b['layers'][0]['shapes']) if i in chosen_top]
        layer['shapes']=result_shapes
    else:
        kind,idx,*_=catalog[number]
        if kind=='item':
            del layer['shapes'][0]['it'][idx]
        else:
            del layer['shapes'][idx]
    current['nm'] = 'PulseDeck diagnostic B matrix '+variant
    return current, catalog


def encode_array(tag, data):
    rows=[f'const uint8_t {tag}_json[] = {{']
    raw=data+b'\0'
    for off in range(0,len(raw),24):
        rows.append('    '+', '.join('0x%02x'%b for b in raw[off:off+24])+',')
    rows.extend(['};',f'const uint32_t {tag}_len = {len(data)}u;',f'/* {tag} SHA256={hashlib.sha256(data).hexdigest()} */'])
    return '\n'.join(rows)


def run(raw, variant):
    if hashlib.sha256(raw).hexdigest()!=EXPECTED_SHA:
        raise ValueError('source Meteocons SHA256 mismatch')
    source=json.loads(raw)
    if not isinstance(source.get('layers'),list) or len(source['layers'])!=2:
        raise ValueError('expected exact two Meteocons layers')
    a=selection(source,'a')
    b=selection(source,'b')
    # EXACT reduction from test_002-3 stable fixture, so split_reduced tests the same visual disk.
    first=b['layers'][0]['shapes'][0]
    bases,catalog=shape_catalog(b['layers'][0])
    reduced=copy.deepcopy(b)
    reduced['layers'][0]['shapes']=[copy.deepcopy(first)]
    reduced['layers'][0]['shapes'][0]['it']=[copy.deepcopy(x) for i,x in enumerate(first['it']) if i in bases]
    reduced['nm']='PulseDeck diagnostic B simplified'
    matrix,cat=make_b_matrix(b,variant)
    values={'a':stable_json(a),'b_full':stable_json(b),'b_reduced':stable_json(reduced),'selected':stable_json(matrix)}
    c='/* BUILD-GENERATED diagnostic variants; Meteocons MIT. */\n#include <stdint.h>\n'
    c+='\n'.join(encode_array('pd_diag_'+key, val) for key,val in values.items())
    c+=f'\nconst uint32_t pd_diag_frames = {round(source["op"]-source["ip"])}u;\n'
    print(f'PD_DIAG source={EXPECTED_SHA} shape_case={variant} optional_pieces={len(cat)}')
    for n,(kind,index,typ,label) in enumerate(cat):
        print(f'  SHAPE_ITEM {n}: {kind}[{index}] type={typ} name={label!r}')
    for key,val in values.items():
        print(f'  {key} bytes={len(val)} sha256={hashlib.sha256(val).hexdigest()}')
    return c.encode('utf-8')


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--out-c',type=Path,required=True)
    p.add_argument('--shape-case',default='add:0')
    args=p.parse_args()
    payload=run(args.source.read_bytes(),args.shape_case)
    args.out_c.parent.mkdir(parents=True,exist_ok=True)
    if not args.out_c.exists() or args.out_c.read_bytes()!=payload:
        args.out_c.write_bytes(payload)

if __name__ == '__main__': main()
