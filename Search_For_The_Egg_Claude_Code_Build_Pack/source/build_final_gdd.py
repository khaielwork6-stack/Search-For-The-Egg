from pathlib import Path
import csv
import html
import re

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Frame, Image, KeepTogether, NextPageTemplate, PageBreak,
    PageTemplate, Paragraph, Spacer, Table, TableStyle
)
from reportlab.platypus.tableofcontents import TableOfContents


PACK = Path(__file__).resolve().parents[1]
ROOT = PACK.parent
OUT = PACK / 'FINAL_GDD.pdf'
KF = ROOT / 'video_audit' / 'keyframes'

for name, path in [
    ('BodyFont', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
    ('BodyBold', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'),
    ('Mono', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'),
]:
    pdfmetrics.registerFont(TTFont(name, path))

NAVY = colors.HexColor('#102532')
INK = colors.HexColor('#24323A')
MUTED = colors.HexColor('#647680')
TEAL = colors.HexColor('#007F78')
GOLD = colors.HexColor('#B47710')
PALE = colors.HexColor('#F2F6F6')
LINE = colors.HexColor('#D4DEE1')
WHITE = colors.white
GREEN_PALE = colors.HexColor('#E7F4F1')
GOLD_PALE = colors.HexColor('#FBF1DC')

ss = getSampleStyleSheet()
BODY = ParagraphStyle('Body', parent=ss['BodyText'], fontName='BodyFont', fontSize=8.3, leading=11.5, textColor=INK, spaceAfter=5)
SMALL = ParagraphStyle('Small', parent=BODY, fontSize=6.9, leading=9.1, textColor=MUTED)
H1 = ParagraphStyle('H1', parent=ss['Heading1'], fontName='BodyBold', fontSize=19, leading=22, textColor=NAVY, spaceBefore=4, spaceAfter=9, keepWithNext=True)
H2 = ParagraphStyle('H2', parent=ss['Heading2'], fontName='BodyBold', fontSize=12.4, leading=15, textColor=NAVY, spaceBefore=8, spaceAfter=5, keepWithNext=True)
H3 = ParagraphStyle('H3', parent=ss['Heading3'], fontName='BodyBold', fontSize=9.6, leading=12, textColor=TEAL, spaceBefore=6, spaceAfter=4, keepWithNext=True)
H4 = ParagraphStyle('H4', parent=BODY, fontName='BodyBold', fontSize=8.7, leading=11, textColor=GOLD, spaceBefore=5, spaceAfter=3, keepWithNext=True)
TITLE = ParagraphStyle('Title', parent=ss['Title'], fontName='BodyBold', fontSize=29, leading=32, textColor=NAVY, alignment=TA_LEFT, spaceAfter=10)
DECK = ParagraphStyle('Deck', parent=BODY, fontSize=11.3, leading=15.5, textColor=MUTED, spaceAfter=12)
CODE = ParagraphStyle('Code', parent=BODY, fontName='Mono', fontSize=6.5, leading=8.5, backColor=colors.HexColor('#EEF2F3'), borderColor=LINE, borderWidth=0.5, borderPadding=6, spaceBefore=3, spaceAfter=6)
CAPTION = ParagraphStyle('Caption', parent=SMALL, fontSize=6.2, leading=8, alignment=TA_CENTER)
TABLE_H = ParagraphStyle('TableH', parent=SMALL, fontName='BodyBold', textColor=WHITE, fontSize=6.2, leading=7.5)
TABLE_B = ParagraphStyle('TableB', parent=SMALL, textColor=INK, fontSize=6.0, leading=7.4)


def inline(text):
    text = html.escape(text.strip(), quote=False)
    text = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'<link href="\2" color="#007F78">\1</link>', text)
    text = re.sub(r'`([^`]+)`', r'<font name="Mono" color="#8A4B08">\1</font>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<i>\1</i>', text)
    return text


def P(text, style=BODY):
    return Paragraph(inline(text), style)


def md_table(lines):
    rows = []
    for line in lines:
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if all(re.fullmatch(r':?-{3,}:?', c) for c in cells):
            continue
        rows.append(cells)
    if not rows:
        return Spacer(1, 1)
    n = max(len(r) for r in rows)
    rows = [r + [''] * (n-len(r)) for r in rows]
    page_width = 174*mm
    widths = [page_width/n] * n
    data = []
    for i, row in enumerate(rows):
        style = TABLE_H if i == 0 else TABLE_B
        data.append([P(c, style) for c in row])
    t = Table(data, colWidths=widths, repeatRows=1, hAlign='LEFT')
    commands = [
        ('BACKGROUND',(0,0),(-1,0),NAVY), ('GRID',(0,0),(-1,-1),0.35,LINE),
        ('VALIGN',(0,0),(-1,-1),'TOP'),
        ('LEFTPADDING',(0,0),(-1,-1),3),('RIGHTPADDING',(0,0),(-1,-1),3),
        ('TOPPADDING',(0,0),(-1,-1),3),('BOTTOMPADDING',(0,0),(-1,-1),3),
    ]
    for i in range(2, len(data), 2):
        commands.append(('BACKGROUND',(0,i),(-1,i),PALE))
    t.setStyle(TableStyle(commands))
    return t


def parse_markdown(path, demote=0, page_break_before=False):
    lines = path.read_text(encoding='utf-8').splitlines()
    out = [PageBreak()] if page_break_before else []
    i = 0
    para = []
    def flush():
        nonlocal para
        if para:
            out.append(P(' '.join(x.strip() for x in para)))
            para = []
    while i < len(lines):
        line = lines[i]
        if line.startswith('```'):
            flush()
            lang = line[3:].strip()
            block = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                block.append(lines[i])
                i += 1
            label = f'{lang.upper()} SPECIFICATION\n' if lang else ''
            out.append(Paragraph(html.escape(label + '\n'.join(block)).replace('\n','<br/>'), CODE))
        elif line.startswith('|'):
            flush()
            tbl = []
            while i < len(lines) and lines[i].startswith('|'):
                tbl.append(lines[i])
                i += 1
            out.append(md_table(tbl))
            out.append(Spacer(1, 3*mm))
            continue
        elif re.match(r'^#{1,4} ', line):
            flush()
            m = re.match(r'^(#{1,4}) (.+)$', line)
            level = min(4, len(m.group(1)) + demote)
            style = {1:H1,2:H2,3:H3,4:H4}[level]
            out.append(P(m.group(2), style))
        elif re.match(r'^[-*] ', line):
            flush()
            out.append(Paragraph('• ' + inline(line[2:]), BODY))
        elif re.match(r'^\d+\. ', line):
            flush()
            out.append(Paragraph(inline(line), BODY))
        elif not line.strip():
            flush()
            out.append(Spacer(1, 1.2*mm))
        else:
            para.append(line)
        i += 1
    flush()
    return out


class GDDDoc(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if isinstance(flowable, Paragraph) and flowable.style.name in {'H1','H2'}:
            level = 0 if flowable.style.name == 'H1' else 1
            text = flowable.getPlainText()
            key = f'h{level}-{self.seq.nextf("heading")}'
            self.canv.bookmarkPage(key)
            if level == 0:
                self.canv.addOutlineEntry(text, key, level=0, closed=False)
            self.notify('TOCEntry', (level, text, self.page, key))


def page_frame(canvas, doc):
    canvas.saveState()
    w, h = A4
    canvas.setStrokeColor(LINE)
    canvas.line(18*mm, h-14*mm, w-18*mm, h-14*mm)
    canvas.setFont('BodyBold', 6.2)
    canvas.setFillColor(NAVY)
    canvas.drawString(18*mm, h-10.5*mm, 'SEARCH FOR THE EGG  |  FINAL GDD')
    canvas.setFont('BodyFont', 6.2)
    canvas.setFillColor(MUTED)
    canvas.drawRightString(w-18*mm, h-10.5*mm, 'Version 1.0  |  12 Sep 2026')
    canvas.line(18*mm, 13*mm, w-18*mm, 13*mm)
    canvas.drawString(18*mm, 8.5*mm, 'Clean-room functional reconstruction  |  Original expression required')
    canvas.drawRightString(w-18*mm, 8.5*mm, str(doc.page))
    canvas.restoreState()


def cover(canvas, doc):
    canvas.saveState()
    w, h = A4
    canvas.setFillColor(NAVY)
    canvas.rect(0, h-22*mm, w, 22*mm, fill=1, stroke=0)
    canvas.setFillColor(TEAL)
    canvas.rect(0, 0, 8*mm, h, fill=1, stroke=0)
    canvas.setFillColor(MUTED)
    canvas.setFont('BodyFont', 6.2)
    canvas.drawRightString(w-18*mm, 8.5*mm, '1')
    canvas.restoreState()


doc = GDDDoc(str(OUT), pagesize=A4, leftMargin=18*mm, rightMargin=18*mm, topMargin=20*mm, bottomMargin=18*mm,
             title='Search for the Egg - Final Game Design Document', author='OpenAI')
doc.addPageTemplates([
    PageTemplate(id='cover', frames=[Frame(23*mm,24*mm,165*mm,242*mm,id='coverFrame')], onPage=cover),
    PageTemplate(id='body', frames=[Frame(doc.leftMargin,doc.bottomMargin,doc.width,doc.height,id='bodyFrame')], onPage=page_frame),
])

story = [Spacer(1, 18*mm), P('FINAL GAME DESIGN DOCUMENT', ParagraphStyle('eyebrow', parent=BODY, fontName='BodyBold', fontSize=8, leading=10, textColor=TEAL, spaceAfter=6)),
         P('Search for the Egg', TITLE),
         P('Development-grade design, systems, economy, architecture, monetization, game-feel, implementation phases, assumptions, and verification standards.', DECK)]

story.append(Table([[P('PRODUCTION DECISION', ParagraphStyle('boxH', parent=BODY, fontName='BodyBold', textColor=TEAL, fontSize=7)),
                     P('Proceed now using centralized ASSUMED behavior for evidence gaps. No additional footage is required to begin.', ParagraphStyle('boxB', parent=BODY, fontName='BodyBold', fontSize=10, leading=13))]],
                   colWidths=[38*mm,124*mm], style=TableStyle([
                       ('BACKGROUND',(0,0),(-1,-1),GREEN_PALE),('BOX',(0,0),(-1,-1),0.8,TEAL),
                       ('VALIGN',(0,0),(-1,-1),'MIDDLE'),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),
                       ('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8)])))
story += [Spacer(1, 8*mm), P('Document controls', H2),
          md_table([
              '| Field | Value |','|---|---|',
              '| Target | Search for the Egg |',
              '| Reference | Search For The Needle by Garage Games |',
              '| Evidence | User recording plus public current/historical research |',
              '| Evidence date | 12 September 2026 |',
              '| Implementation | Six controlled Claude Code phases |',
              '| Authority | MASTER_SPEC.md and SYSTEM_CONFIG.json |',
          ]), Spacer(1, 7*mm), P('Premium bar', H2),
          P('Every phase must include purposeful animation, ambient movement, layered audio, responsive UI, satisfying feedback, strong lighting, polished VFX, environmental activity, cleanup, and mobile-aware performance. Phase 6 completes and measures polish; it does not introduce it for the first time.'),
          NextPageTemplate('body'), PageBreak(), P('Contents', H1)]

toc = TableOfContents()
toc.levelStyles = [
    ParagraphStyle('TOC1', parent=BODY, fontName='BodyBold', fontSize=8.2, leading=11, leftIndent=0, firstLineIndent=0, textColor=NAVY),
    ParagraphStyle('TOC2', parent=SMALL, fontSize=7.1, leading=9.5, leftIndent=10*mm, firstLineIndent=0, textColor=MUTED),
]
story += [toc, PageBreak()]

story += parse_markdown(PACK/'source'/'GDD_PREFACE.md', demote=0)

# Visual evidence spread
story += [PageBreak(), P('Observed-build visual evidence', H1),
          P('These frames are from the supplied recording and establish the visual/UI source boundary. They are evidence, not assets for reuse.'),]
if KF.exists():
    imgs = [
        ('t3.png','Daily rewards and live update countdown'),
        ('t14.png','Class odds and roll surface'),
        ('t145.png','Compact Farmhouse collection space'),
        ('t227.png','Vacuum acquisition and heat mechanic'),
    ]
    cells=[]
    for fn, cap in imgs:
        p=KF/fn
        if p.exists():
            im=Image(str(p), width=82*mm, height=46.125*mm)
            cells.append(Table([[im],[P(cap,CAPTION)]], colWidths=[82*mm], style=TableStyle([
                ('BOX',(0,0),(-1,0),0.4,LINE),('BACKGROUND',(0,1),(-1,1),PALE),
                ('LEFTPADDING',(0,0),(-1,-1),0),('RIGHTPADDING',(0,0),(-1,-1),0),
                ('TOPPADDING',(0,0),(-1,-1),0),('BOTTOMPADDING',(0,0),(-1,-1),3)])))
    if len(cells)>=4:
        story.append(Table([[cells[0],cells[1]],[cells[2],cells[3]]], colWidths=[86*mm,86*mm], style=TableStyle([
            ('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),1),('RIGHTPADDING',(0,0),(-1,-1),1),('TOPPADDING',(0,0),(-1,-1),2)])))
story += [Spacer(1, 5*mm), P('Observed facts include the 25-feather starting bag, class weights totaling 100%, Daily reward amounts, four tool families, party capacity up to four, a count-up round timer, Chapter/Hard one-win locks, and visible purchase packaging. Completion and later systems are explicitly assumed in the build pack.')]

# Main specification
story += parse_markdown(PACK/'MASTER_SPEC.md', demote=0, page_break_before=True)

# Economy overview from CSV, grouped and capped to key rows
story += [PageBreak(), P('Economy reference tables', H1),
          P('The complete editable table is supplied as ECONOMY_TABLES.csv. The following compact view highlights core progression and product values. SYSTEM_CONFIG.json remains authoritative.')]
with open(PACK/'ECONOMY_TABLES.csv', newline='', encoding='utf-8') as f:
    rows=list(csv.DictReader(f))
for group, title in [('bag','Bag progression'),('tool','Tool acquisition'),('reward','Completion rewards'),('daily','Daily rewards'),('class','Class distribution'),('product','Robux products')]:
    subset=[r for r in rows if r['table']==group]
    if not subset: continue
    story += [P(title,H2)]
    table_lines=['| ID | Level | Value | Cost | Evidence |','|---|---|---|---|---|']
    for r in subset[:12]:
        val=f"{r['value']} {r['value_unit']}"
        cost=f"{r['cost']} {r['cost_currency']}" if r['cost'] else '-'
        table_lines.append(f"| {r['id']} | {r['level']} | {val} | {cost} | {r['evidence']} |")
    story.append(md_table(table_lines))

# Key technical appendices
story += [PageBreak(), P('Technical implementation appendices', H1),
          P('The standalone Markdown files contain the complete working contracts. These summaries preserve the key architecture decisions in the human-readable GDD.'),
          P('Persistence and transactions', H2),
          P('Persistent profiles contain premium currencies, wins/unlocks, best times, classes, permanent perks, cosmetics, daily/code claims, settings, tutorial progress, and aggregate stats. Round cash, bag/tool levels, carried feathers, and one-round grants remain session-scoped. Rewards and developer-product receipts use stable idempotency keys. The server commits reward state before teleport and never starts a disposable writable profile after a failed load.'),
          P('State-machine invariants', H2),
          P('Lobby, party, round, collection, selling, upgrades, Egg reveal, victory, death, rejoin, tools, puzzles, and receipts are explicit state machines. Only valid state transitions accept requests. Victory is atomic, joins close at reveal, and receipt acknowledgement follows persistence.'),
          P('Verification model', H2),
          P('A phase is complete only after automated checks, actual Roblox Studio verification, concrete evidence, updated documentation, and a committed checkpoint. If Studio is inaccessible, Claude Code must say so and stop at the same phase; it may not substitute “should work.”')]

# Assumptions appendix
story += parse_markdown(PACK/'ASSUMPTIONS.md', demote=0, page_break_before=True)

# Sources
story += [PageBreak(), P('Research sources', H1),
          P('Accessed 12 September 2026 unless stated. Public metrics and commerce are volatile. The uploaded recording is primary evidence for all directly observed claims.'),
          md_table([
              '| No. | Source | Use / limitation |','|---|---|---|',
              '| 1 | User-supplied 5:25.667 screen recording, 1280x720, 60 FPS | Primary current-build observation; exact deployed build ID unavailable |',
              '| 2 | [Official Roblox experience](https://www.roblox.com/games/77108422251420/Search-For-The-Needle) | Identity, developer, description, root place |',
              '| 3 | [Rolimon’s game record](https://www.rolimons.com/game/77108422251420) | Universe places, badges, max players; third-party snapshot |',
              '| 4 | [Roblox Pivot analytics](https://ropivot.remielshirazi.com/games/10756011174) | Dated CCU/visits/likes/favorites snapshot |',
              '| 5 | [Beebom class guide](https://beebom.com/search-for-the-needle-tier-list/) | Class effect corroboration; weights match live UI |',
              '| 6 | [GamesRadar codes guide](https://www.gamesradar.com/games/simulation/search-for-the-needle-codes/) | ALIEN code corroboration |',
              '| 7 | [TechWiser Basement guide](https://techwiser.com/search-for-the-needle-basement/) | Chapter 2 route/puzzle corroboration |',
              '| 8 | [Pro Game Guides Alien Coins](https://progameguides.com/roblox/how-to-get-alien-coins-in-search-for-the-needle/) | Event currency source hypothesis |',
              '| 9 | [Pro Game Guides Basement](https://progameguides.com/roblox/search-for-the-needle-basement-walkthrough/) | Independent Chapter 2 corroboration |',
              '| 10 | [Needle Wiki gamepasses](https://needle.wiki/guides/search-for-the-needle-gamepasses/) | Historical pass descriptions/prices; live conflicts remain dated |',
          ]), Spacer(1,5*mm),
          P('Clean-room restriction', H2),
          P('No private source code, script decompilation, private endpoints, exploits, stolen assets, or non-public implementation details are used. Target production must create original code, assets, map construction, writing, branding, models, UI, animation, VFX, and audio.'),
          Spacer(1,8*mm), P('End of Final GDD', ParagraphStyle('End',parent=H2,alignment=TA_CENTER,textColor=TEAL))]

doc.multiBuild(story)
print(OUT)
