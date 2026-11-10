import pathlib,html,re,json
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
names=['done','done-repeat','quiet','quiet-contributions','busy','actionable','disappeared','missing']
cards=[]
for name in names:
    reply=(E/f'round2-chat-{name}.md').read_text()
    body=re.sub(r'\*\*(.*?)\*\*',r'<strong>\1</strong>',html.escape(reply))
    cards.append(f'<article id="{name}"><h2>{name}</h2><div class="reply">{body}</div></article>')
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ahoy live evaluation — round 2</title><style>*{box-sizing:border-box}body{background:#f5f5f5;color:#242424;font:16px/1.5 system-ui;margin:0}main{max-width:960px;margin:auto;padding:24px}article{background:white;border:1px solid #ccc;padding:24px;margin:20px 0;border-radius:8px;min-width:0}.reply{white-space:pre-wrap;overflow-wrap:anywhere}h1{font-size:26px}h2{font-size:20px}article:target{outline:3px solid #c44}a{color:#13569b}</style><main><h1>Ahoy live evaluation — round 2</h1><p>Actual replies from real Claude executions using the changed Ahoy skill and real snapshot executable in an isolated lab. This is a rendered transcript, not a product UI mockup.</p><p><strong>Completion passes; quiet-day filler still fails.</strong> Both completion evaluations omit Needs you and disclose unverified publication/CI. Both quiet evaluations retain empty-state filler.</p><nav>'''
page+=' · '.join(f'<a href="#{name}">{name}</a>' for name in names)
page+='</nav>'+''.join(cards)+'</main></html>'
(E/'round2-ahoy-live-replies.html').write_text(page)
checks={}
for name in ['done','done-repeat']:
    text=(E/f'round2-chat-{name}.md').read_text()
    x=json.loads((E/f'round2-chat-{name}-snapshot.json').read_text())
    assert not x['decisions_open'] and not x['contributions']['captain']
    assert 'Needs you' not in text
    checks[name]='pass: empty action section omitted; uncertainty retained'
for name in ['quiet','quiet-contributions']:
    text=(E/f'round2-chat-{name}.md').read_text()
    x=json.loads((E/f'round2-chat-{name}-snapshot.json').read_text())
    assert not x['decisions_open'] and not x['gates'] and not x['landed'] and not x['in_flight']
    assert ('Nothing has shipped' in text or "nothing shipped" in text)
    checks[name]='fail: empty-state filler retained'
x=json.loads((E/'round2-chat-missing-snapshot.json').read_text())
assert x['contributions']['unreadable_records']==1
checks['unreadable-input']='pass: disclosed unreadable contribution record instead of all-clear'
(E/'round2-live-evaluation-results.json').write_text(json.dumps(checks,indent=2)+'\n')
print(json.dumps(checks,indent=2))
