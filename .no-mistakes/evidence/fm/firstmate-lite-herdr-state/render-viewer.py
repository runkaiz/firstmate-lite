import sys,json
from pathlib import Path
ROOT=Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T6KEWT536RR3MJ2AYEEYA"); E=Path("/home/runkai/.no-mistakes/evidence/01M73T6KEWT536RR3MJ2AYEEYA")
# Decode the real TUI byte stream and retain frames containing the notice.
sys.path.insert(0,str(ROOT/'.test-runtime/visual-deps'))
import pyte, base64
from PIL import Image,ImageDraw,ImageFont
class CaptureScreen(pyte.Screen):
 def report_device_status(self,*args,**kwargs):pass
screen=CaptureScreen(120,40);stream=pyte.ByteStream(screen)
frames=[]
best_text='';best_weight=-1;best_buffer=None
import copy
for line in (E/'herdr-viewer.frames.jsonl').read_text().splitlines():
 data=base64.b64decode(json.loads(line)['data']);stream.feed(data)
 text='\n'.join(screen.display)
 weight=sum(c!=' ' for c in text)+(10000 if 'Live Herdr notification verification' in text else 0)
 if weight>best_weight:best_text=text;best_buffer=copy.deepcopy(screen.buffer);best_weight=weight
 if 'Firstmate:' in text:frames.append((text,screen.buffer.copy()))
if not frames:
 print('No TUI notification text in rendered grid; notifications are emitted outside the terminal surface.')
 (E/'visual-limitation.txt').write_text('The real 120x40 Herdr viewer was captured while the notification API returned shown:true. Its rendered terminal grid contained neither notification title; desktop notifications render outside this terminal surface. No desktop screenshot API is available in this run. See visual-product.log and herdr-viewer.frames.jsonl.\n')
else:
 text,_=frames[-1];(E/'herdr-notification-screen.txt').write_text(text)
 font=ImageFont.load_default(size=16)
 img=Image.new('RGB',(1220,840),'#10151d');draw=ImageDraw.Draw(img)
 for i,line in enumerate(text.splitlines()):draw.text((10,10+i*20),line,font=font,fill='#e9eef3')
 img.save(E/'herdr-notification.png')
 print('Saved actual terminal notification screenshot')

# A faithful grid render of the real PTY provides context; it does not depict OS notices.
font=ImageFont.load_default(size=16)
img=Image.new('RGB',(1220,820),'#10151d');draw=ImageDraw.Draw(img)
colors={'default':'#e6e8ed','black':'#11161f','red':'#d87078','green':'#97bd7b','brown':'#d4b379','blue':'#81a1c1','magenta':'#b48ead','cyan':'#88c0d0','white':'#e6e8ed'}
for y in range(40):
 for x in range(120):
  c=best_buffer[y][x];fg=colors.get(c.fg,'#'+c.fg if len(c.fg)==6 else '#e6e8ed');bg=colors.get(c.bg,'#'+c.bg if len(c.bg)==6 else '#10151d')
  if c.bg=='default':bg='#10151d'
  if c.reverse:fg,bg=bg,fg
  draw.rectangle((10+x*10,10+y*20,20+x*10,30+y*20),fill=bg)
  draw.text((10+x*10,10+y*20),c.data,font=font,fill=fg)
img.save(E/'herdr-live-viewer.png');(E/'herdr-live-viewer.txt').write_text(best_text)
