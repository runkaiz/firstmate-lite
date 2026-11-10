import pathlib,json,html,re
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
cards=[]
results={}
for name in ['done','quiet','moving','moving-repeat','disappeared','missing','busy']:
    file=E/f'chat-{name}.stream.jsonl'
    rows=[json.loads(line) for line in file.read_text().splitlines()]
    result=next(x for x in rows if x.get('type')=='result')
    assert result['subtype']=='success' and not result['is_error'] and result['permission_denials']==[]
    text=result['result']
    (E/f'chat-{name}.md').write_text(text+'\n')
    snapshots=[]
    commands=[]
    for event in rows:
        for block in event.get('message',{}).get('content',[]):
            if block.get('type')=='tool_use': commands.append(block['input'])
            if block.get('type')=='tool_result':
                try: data=json.loads(block['content'])
                except (ValueError,TypeError): continue
                if data.get('schema')=='fm-bearings.v1': snapshots.append(data)
    assert len(snapshots)==1
    (E/f'chat-{name}-snapshot.json').write_text(json.dumps(snapshots[0],indent=2)+'\n')
    (E/f'chat-{name}-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    results[name]=(text,snapshots[0])
    body=html.escape(text)
    body=re.sub(r'\*\*(.*?)\*\*',r'<strong>\1</strong>',body)
    cards.append(f'<article id="{name}"><h2>{html.escape(name)}</h2><div class="reply">{body}</div></article>')
text,snap=results['done']
assert snap['in_flight'][0]['state']=='done' and snap['in_flight'][0]['stage']=='done'
assert 'unverified' in snap['in_flight'][0]['doing']
assert snap['decisions_open']==[] and snap['contributions']['captain']==[]
assert '**Needs you:** Nothing right now.' in text
assert results['quiet'][1]['contributions']['known']==71
assert results['quiet'][1]['contributions']['counts']==dict(captain=0,fleet=2,maintainer=1,nobody=68)
assert all(word not in results['quiet'][0] for word in ['71','maintainer','**Shipped**','**Moving**','**Next**','**Needs you**'])
assert results['moving'][1]['in_flight'][0]['stage']=='implementing'
assert 900<=results['moving'][1]['in_flight'][0]['elapsed_seconds']<960
assert len(results['moving'][1]['decisions_open'])==1
assert all(x['current']=='no longer observed' for x in results['disappeared'][1]['since_last_look']['changes'])
assert {x['surface'] for x in results['disappeared'][1]['since_last_look']['changes']}=={'moving','call'}
assert any('backlog' in x['surface'] for x in results['missing'][1]['omitted'])
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Actual Ahoy replies — live validation</title><style>
*{box-sizing:border-box}body{margin:0;background:#f6ecd3;color:#3f3224;font:16px/1.55 system-ui,sans-serif}main{max-width:1000px;margin:auto;padding:32px 24px}h1,h2{color:#241c14}h1{font-size:27px}h2{text-transform:capitalize;font-size:19px;margin:0 0 16px}article{min-width:0;background:#fffdf7;border:1px solid #ddc89c;border-radius:12px;padding:24px;margin:24px 0}.reply{white-space:pre-wrap;overflow-wrap:anywhere}strong{color:#241c14}a{color:#2f6688}.note{color:#6f5e46}article:target{outline:3px solid #e0a52e}
</style><main><h1>Actual Ahoy replies</h1><p class="note">Saved responses from real Claude executions on a private 120×40 tmux lab, using the exact Ahoy skill and the real snapshot executable. This page displays the observed replies; it is not a mockup of a Firstmate UI. Fixture data is disposable. Colors follow the repository’s board tokens.</p><nav>'''
page+=' · '.join(f'<a href="#{x}">{x}</a>' for x in results)
page+='</nav>'+''.join(cards)+'</main></html>'
(E/'ahoy-live-replies.html').write_text(page)
(E/'live-evaluation-checks.json').write_text(json.dumps(dict(
    empty_action_section='FAIL: completion reply emits Needs you: Nothing right now despite no actionable rows',
    uncertainty='PASS',quiet_contribution_suppression='PASS',moving_stage_and_timing='PASS',disappeared_rows='PASS',missing_state_disclosure='PASS'),indent=2)+'\n')
print('Extracted actual replies, snapshots, tool commands and rendered transcript. Confirmed the empty action-section failure.')
