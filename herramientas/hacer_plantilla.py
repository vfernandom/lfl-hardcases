import sys
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.comments import Comment

F = 'Arial'
H = Font(name=F, bold=True, color='FFFFFF', size=11)
HF = PatternFill('solid', fgColor='16181B')
REQ = PatternFill('solid', fgColor='FFF4D6')   # columnas obligatorias
N = Font(name=F, size=10)
B = Font(name=F, size=10, bold=True)
thin = Side(style='thin', color='D3D0C9')

ROLES = ['Placa','Perfil','Espuma','Cierre','Manija','Bisagra','Esquinero','Consumibles','Otro']
MATS = [('Placa fenólico 9 mm','Placa','m²',95000,''),('Perfil aluminio unión','Perfil','m',28000,''),('Espuma 10 mm','Espuma','m²',40000,''),
        ('Cierre mariposa','Cierre','unidad',35000,''),('Manija retráctil','Manija','unidad',30000,''),('Bisagra','Bisagra','unidad',15000,''),
        ('Esquinero bola','Esquinero','unidad',9000,''),('Remaches y consumibles (kit)','Consumibles','kit',15000,'')]

wb = Workbook()
ins = wb.active; ins.title = 'Instrucciones'
lines = [
 ('PLANTILLA DE CATÁLOGO · LFL HARDCASE', 'title'),
 ('', None),
 ('Cómo usarla', 'h'),
 ('1. Completá las hojas Materiales, Productos y Recetas. Las columnas marcadas «Obligatorio» (fondo amarillo, fila 2) no pueden quedar vacías.', None),
 ('2. En la app: Catálogo y costos → Importar desde Excel → elegí este archivo.', None),
 ('3. La app muestra qué va a crear, qué va a actualizar y los errores ANTES de guardar. Recién al confirmar se guarda.', None),
 ('4. Para editar lo que ya está cargado: Catálogo y costos → Exportar a Excel, modificá y volvé a importar.', None),
 ('', None),
 ('Reglas', 'h'),
 ('• Materiales: se reconocen por el NOMBRE (sin importar mayúsculas ni tildes). Si existe, se actualiza; si no, se crea.', None),
 ('• Productos: se reconocen por el CÓDIGO (ej. GC1). Si existe, se actualiza; si no, se crea.', None),
 ('• Recetas: una fila por cada material de cada producto. El material debe existir en la hoja Materiales o en la app.', None),
 ('  Si un producto tiene filas en Recetas, su lista de materiales se REEMPLAZA por la del archivo. Si no tiene, se conserva la que tenía.', None),
 ('• Importar nunca borra: lo que no está en el archivo queda como estaba.', None),
 ('• Precios en guaraníes, sin puntos ni símbolo (95000). Cantidades con decimales: 1,5 o 1.5.', None),
 ('• Precio del material = costo por unidad, SIN IVA (es lo que usa el cálculo del presupuesto).', None),
 ('• Rol del material: lo usa la app para estimar trabajos A MEDIDA. Valores: ' + ', '.join(ROLES) + '.', None),
 ('• IVA del producto: 10, 5 o Exento. Vacío = usa el IVA general de la app.', None),
 ('', None),
 ('Ejemplo de un producto completo (NO se importa desde esta hoja)', 'h'),
 ('Productos →  GC1 | Estuche guitarra clásica | 105 × 42 × 14 cm | 6 | 10 | 650000 | Interior de espuma negra', None),
 ('Recetas   →  GC1 | Placa fenólico 9 mm | 1,6', None),
 ('              GC1 | Perfil aluminio unión | 6,4', None),
 ('              GC1 | Cierre mariposa | 2', None),
 ('', None),
 ('Los materiales que vienen cargados en la hoja Materiales son los de EJEMPLO de la app: reemplazá precios y nombres por los reales.', 'warn'),
]
for i,(t,k) in enumerate(lines, start=1):
    c = ins.cell(row=i, column=1, value=t)
    c.font = Font(name=F, size=16 if k=='title' else 11, bold=k in ('title','h'), color='D9480F' if k=='warn' else '000000')
    c.alignment = Alignment(wrap_text=True, vertical='top')
ins.column_dimensions['A'].width = 120

def hoja(nombre, cols, widths, obligatorias, notas):
    ws = wb.create_sheet(nombre)
    for j,(c,w) in enumerate(zip(cols, widths), start=1):
        cell = ws.cell(row=1, column=j, value=c); cell.font = H; cell.fill = HF
        cell.alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)
        ws.column_dimensions[cell.column_letter].width = w
        if c in notas: cell.comment = Comment(notas[c], 'LFL')
        sub = ws.cell(row=2, column=j, value='Obligatorio' if c in obligatorias else 'Opcional')
        sub.font = Font(name=F, size=9, italic=True, color='73716C'); sub.alignment = Alignment(horizontal='center')
        if c in obligatorias: sub.fill = REQ
    ws.row_dimensions[1].height = 30
    ws.freeze_panes = 'A3'
    return ws

mat = hoja('Materiales', ['Material','Rol','Unidad','Precio unitario ₲ (costo sin IVA)','Proveedor'], [36,16,12,26,28],
           {'Material','Unidad','Precio unitario ₲ (costo sin IVA)'},
           {'Rol':'Sirve para estimar trabajos a medida (placa = superficie, perfil = aristas, etc.).','Unidad':'m², m, unidad, kit, litro…'})
for i,m in enumerate(MATS, start=3):
    for j,v in enumerate(m, start=1):
        c = mat.cell(row=i, column=j, value=v); c.font = N
        if j == 4: c.number_format = '#,##0'
pro = hoja('Productos', ['Código','Nombre','Medidas estándar','Horas por unidad','IVA','Precio actual ₲','Notas'], [12,34,22,16,10,18,36],
           {'Código','Nombre','Horas por unidad'},
           {'Código':'Único por producto, ej. GC1. Es lo que se usa para reconocerlo al reimportar.','Horas por unidad':'Horas de fabricación de 1 unidad (ej. 6 o 6,5).','Precio actual ₲':'Opcional: precio de venta actual para compararlo con el sugerido.'})
rec = hoja('Recetas', ['Código producto','Material','Cantidad por unidad'], [18,36,20],
           {'Código producto','Material','Cantidad por unidad'},
           {'Material':'Elegí de la lista (sale de la hoja Materiales).','Cantidad por unidad':'En la unidad del material: m², m, unidades…'})

dv_rol = DataValidation(type='list', formula1='"' + ','.join(ROLES) + '"', allow_blank=True, showErrorMessage=True, errorTitle='Rol', error='Elegí un rol de la lista.')
mat.add_data_validation(dv_rol); dv_rol.add('B3:B1000')
dv_pre = DataValidation(type='decimal', operator='greaterThanOrEqual', formula1='0', allow_blank=True, showErrorMessage=True, error='Número mayor o igual a 0, sin puntos ni símbolos.')
mat.add_data_validation(dv_pre); dv_pre.add('D3:D1000')
dv_iva = DataValidation(type='list', formula1='"10,5,Exento"', allow_blank=True, showErrorMessage=True, error='10, 5 o Exento.')
pro.add_data_validation(dv_iva); dv_iva.add('E3:E1000')
dv_h = DataValidation(type='decimal', operator='greaterThan', formula1='0', allow_blank=True, showErrorMessage=True, error='Horas mayores a 0.')
pro.add_data_validation(dv_h); dv_h.add('D3:D1000')
dv_m = DataValidation(type='list', formula1='Materiales!$A$3:$A$1000', allow_blank=True, showErrorMessage=False)
rec.add_data_validation(dv_m); dv_m.add('B3:B5000')
dv_p = DataValidation(type='list', formula1='Productos!$A$3:$A$1000', allow_blank=True, showErrorMessage=False)
rec.add_data_validation(dv_p); dv_p.add('A3:A5000')
for ws in (pro, rec):
    for r in ws.iter_rows(min_row=3, max_row=60):
        for c in r: c.font = N
pro.column_dimensions['F'].width = 18
for r in range(3, 1001): pro.cell(row=r, column=6).number_format = '#,##0'
wb.active = 1
wb.save(sys.argv[1])
print('ok')
