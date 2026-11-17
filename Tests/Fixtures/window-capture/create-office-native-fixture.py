from pathlib import Path
import argparse
import json
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill, Border, Side, Alignment
from openpyxl.worksheet.views import Selection

parser = argparse.ArgumentParser(description='Create a synthetic, local-only Excel quality fixture.')
parser.add_argument('--output-dir', type=Path, required=True)
root = parser.parse_args().output_dir.resolve()
root.mkdir(parents=True, exist_ok=True)
path = root / 'KKRemote-Office-Native-HDR-20261115.xlsx'
wb = Workbook()
ws = wb.active
ws.title = 'Native quality'
ws.sheet_view.zoomScale = 150
ws.sheet_view.zoomScaleNormal = 100
ws.sheet_view.showGridLines = False
ws.sheet_view.selection = [Selection(activeCell='A1', sqref='A1')]
ws.sheet_view.topLeftCell = 'A1'
ws.sheet_properties.pageSetUpPr.fitToPage = True
for col, width in {'A':8,'B':15,'C':11,'D':8}.items():
    ws.column_dimensions[col].width = width
for row in range(1,251):
    ws.row_dimensions[row].height = 23
    for cell in ws[row][:4]:
        cell.font = Font(name='Arial',size=11,color='101820')
        cell.alignment = Alignment(vertical='center',wrap_text=False)

def spanning(row,text,size,color='101820',fill=None):
    ws.merge_cells(start_row=row,start_column=1,end_row=row,end_column=4)
    c=ws.cell(row,1,text);c.font=Font(name='Arial',size=size,color=color)
    if fill:
        for col in range(1,5):ws.cell(row,col).fill=PatternFill('solid',fgColor=fill)
    ws.row_dimensions[row].height=max(22,size*1.5)

ws.row_dimensions[1].height=8
spanning(2,'KKRemote Excel 清晰度',14)
spanning(3,'150% 文档缩放 · 原生窗口',11,'505A64')
spanning(5,'9 pt  Aa 0123456789 中文细节',9)
spanning(6,'11 pt Aa 0123456789 中文细节',11)
spanning(7,'14 pt Aa 0123456789 中文细节',14)
spanning(9,'9 pt  Red 文字 红色细笔画',9,'E4252B')
spanning(10,'11 pt Blue 文字 蓝色细笔画',11,'1259DB')
spanning(11,'14 pt 白色细节 White 0123',14,'FFFFFF','141820')
for col,color in enumerate(['000000','555555','AAAAAA','FFFFFF'],1):
    cell=ws.cell(13,col,['0','85','170','255'][col-1]);cell.fill=PatternFill('solid',fgColor=color)
    cell.font=Font(name='Arial',size=11,color='FFFFFF' if col<3 else '000000')
    cell.alignment=Alignment(horizontal='center',vertical='center')
for col,color in enumerate(['FF0000','00AA00','0000FF','FF00FF'],1):
    ws.cell(14,col).fill=PatternFill('solid',fgColor=color)
ws.row_dimensions[13].height=25;ws.row_dimensions[14].height=16
spanning(16,'细线表格 / Scroll table',11)
for col,v in enumerate(['行号','名称 Name','数值 Value','字形'],1):
    cell=ws.cell(18,col,v);cell.font=Font(name='Arial',size=11,bold=True,color='FFFFFF');cell.fill=PatternFill('solid',fgColor='1C2F45')
    cell.alignment=Alignment(horizontal='center',vertical='center')
line=Side(style='hair',color='303030')
for row in range(19,251):
    n=row-18; size=[9,11,14][n%3]
    values=[n,f'样本 {n:03d}',n*123.45,'Aa 中']
    for col,v in enumerate(values,1):
        cell=ws.cell(row,col,v);cell.font=Font(name='Arial',size=size,color='101820')
        cell.border=Border(left=line,right=line,top=line,bottom=line)
        cell.fill=PatternFill('solid',fgColor='FFFFFF' if n%2 else 'F0F5F9')
    ws.cell(row,3).number_format='#,##0.00'
    ws.row_dimensions[row].height=25
wb.properties.creator='KKRemote test fixture'
wb.properties.title='Owned office source-pixel fixture'
wb.properties.description='Synthetic SDR spreadsheet for text/geometry validation on an HDR workspace. Not an HDR luminance reference.'
wb.save(path)
check=load_workbook(path)
assert check.active.sheet_view.zoomScale==150
assert [check.active[f'A{i}'].font.sz for i in [5,6,7]]==[9,11,14]
assert check.active.max_row==250
assert not check._external_links
manifest={'path':str(path),'sheet':'Native quality','zoom':150,'fontPoints':[9,11,14],
          'widthColumnUnits':{'A':8,'B':15,'C':11,'D':8},'synthetic':True,
          'knownROIs':{'blackText':'A5:D7','colorText':'A9:D11','SDRGray':'A13:D13','SDRColor':'A14:D14','hairlineTable':'A18:D250'},
          'warning':'Excel cells are SDR. The sheet tests SDR text/UI fidelity in HDR transport; it cannot prove HDR highlight preservation.'}
(root/'fixture.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(path)
