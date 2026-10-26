from fastapi import FastAPI, HTTPException, status, Depends, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel, EmailStr
from supabase import create_client, Client
from passlib.context import CryptContext
from datetime import datetime, timedelta
from jose import JWTError, jwt
import math
import os
import re
from typing import Optional

# 1. Configuración de Supabase
SUPABASE_URL = os.getenv("SUPABASE_URL", "https://gruuoelmqzvjwdcluudz.supabase.co")
SUPABASE_KEY = os.getenv("SUPABASE_KEY", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo")
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# 2. Configuración de Seguridad (JWT y Passlib)
SECRET_KEY = os.getenv("SECRET_KEY", "super-clave-secreta-de-servinow-cambiar-en-produccion")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 480  # 8 horas (con 30 min la app dejaba de recibir mensajes en silencio)

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="login")

app = FastAPI()

# 3. Configuración de CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- MODELOS PYDANTIC ---
class RegistroUsuario(BaseModel):
    nombre: str
    correo: EmailStr
    telefono: str
    contrasena: str
    rol: str

class LoginUsuario(BaseModel):
    correo: EmailStr
    contrasena: str

class PerfilProfesionalUpdate(BaseModel):
    descripcion: Optional[str] = ""
    foto_1: Optional[str] = ""
    foto_2: Optional[str] = ""
    foto_3: Optional[str] = ""

class CrearSolicitud(BaseModel):
    id_profesional: str | int  # Sintaxis moderna compatible con Python 3.10+
    descripcion_problema: str
    direccion_texto: str
    latitud: float
    longitud: float

# Oficios permitidos. Deben contener las palabras que usa el buscador de clientes
# (clima, carpintero, cerrajero, plomero, electricista, pintor).
OFICIOS_VALIDOS = [
    "Plomero",
    "Electricista",
    "Carpintero",
    "Cerrajero",
    "Pintor",
    "Técnico de clima",
]

class CambiarEstadoSolicitud(BaseModel):
    estado: str  # "aceptado" o "rechazado"

class CrearMensaje(BaseModel):
    contenido: str

class CrearCotizacion(BaseModel):
    precio: float
    detalle: Optional[str] = ""

class ResponderCotizacion(BaseModel):
    aceptar: bool

class TerminarTrabajo(BaseModel):
    nota: Optional[str] = ""      # Qué se hizo (opcional)

class ProponerAjuste(BaseModel):
    precio: float
    motivo: str                   # Por qué cambia el precio (obligatorio)

class ResponderAjuste(BaseModel):
    aceptar: bool

class RechazarCierre(BaseModel):
    motivo: str                   # Por qué el cliente considera que aún no está terminado

# Estados en los que el chat sigue habilitado
ESTADOS_CHAT = ("confirmado", "en_curso", "por_verificar", "ajuste_pendiente")

# Flujo de una solicitud:
#   pendiente -> aceptado -> cotizado -> confirmado   (el chat se habilita en "confirmado")
#                              |-> cotizacion_rechazada -> (el profesional envía otra) -> cotizado
#   pendiente -> rechazado
#
# Ejecución del trabajo (después de "confirmado"):
#   confirmado --(profesional inicia)--> en_curso --(profesional termina)--> por_verificar
#   por_verificar --(cliente confirma y califica)--> completado
#   por_verificar --(cliente dice que aún no termina)--> en_curso
#
# Ajuste de precio (mientras el trabajo está "confirmado" o "en_curso"):
#   confirmado/en_curso --(profesional propone nuevo precio)--> ajuste_pendiente
#   ajuste_pendiente --(cliente acepta o rechaza)--> vuelve al estado anterior
#   (si acepta, el precio de la cotización cambia; si rechaza, se mantiene el original)

# --- FUNCIONES AUXILIARES ---
def verificar_contrasena(plain_password, hashed_password):
    return pwd_context.verify(plain_password, hashed_password)

def obtener_password_hash(password):
    return pwd_context.hash(password)

def crear_token_acceso(data: dict, expires_delta: Optional[timedelta] = None):
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + timedelta(minutes=15)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

def obtener_usuario_actual(token: str = Depends(oauth2_scheme)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Token inválido o expirado",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        correo: str = payload.get("sub")
        if correo is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    response = supabase.table("usuarios").select("*").eq("correo", correo).execute()
    if not response.data:
        raise credentials_exception

    return response.data[0]

def calcular_distancia(lat1, lon1, lat2, lon2):
    R = 6371.0  # Radio de la Tierra en kilómetros
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

def obtener_id_profesional(id_usuario) -> Optional[int]:
    """Devuelve el id_profesional ligado a un usuario (o None si no es profesional)."""
    res = supabase.table("profesionales").select("id_profesional").eq("id_usuario", id_usuario).execute()
    return res.data[0]["id_profesional"] if res.data else None

def verificar_participante(id_solicitud: int, usuario: dict) -> dict:
    """
    Devuelve la solicitud solo si el usuario es el cliente o el profesional de ella.
    Lanza 404 si no existe y 403 si el usuario no participa.
    """
    res = supabase.table("solicitudes").select("*").eq("id_solicitud", id_solicitud).execute()
    if not res.data:
        raise HTTPException(status_code=404, detail="Solicitud no encontrada")
    sol = res.data[0]

    es_cliente = str(sol["id_cliente"]) == str(usuario["id_usuario"])
    es_profesional = False
    if usuario["rol"] == "Profesional":
        id_prof = obtener_id_profesional(usuario["id_usuario"])
        es_profesional = id_prof is not None and str(sol["id_profesional"]) == str(id_prof)

    if not (es_cliente or es_profesional):
        raise HTTPException(status_code=403, detail="No participas en esta solicitud")
    return sol

def ahora_iso() -> str:
    return datetime.utcnow().isoformat() + "Z"

def nombre_corto(nombre: str) -> str:
    """'María García López' -> 'María G.' (privacidad en las reseñas públicas)."""
    partes = (nombre or "").strip().split()
    if not partes:
        return "Cliente"
    if len(partes) == 1:
        return partes[0]
    return f"{partes[0]} {partes[1][0].upper()}."

def resumen_calificaciones(ids_prof: list) -> dict:
    """{id_profesional: {'promedio': 4.8, 'total': 12}}. Si la tabla aún no existe, devuelve {}."""
    resultado = {}
    if not ids_prof:
        return resultado
    try:
        filas = supabase.table("resenas").select("id_profesional, calificacion").in_("id_profesional", ids_prof).execute().data
    except Exception:
        return resultado
    acumulado = {}
    for f in filas:
        a = acumulado.setdefault(f["id_profesional"], [0, 0])
        a[0] += f["calificacion"]
        a[1] += 1
    for id_prof, (suma, total) in acumulado.items():
        resultado[id_prof] = {"promedio": round(suma / total, 1), "total": total}
    return resultado

def conteo_completados(ids_prof: list) -> dict:
    """{id_profesional: trabajos completados}."""
    conteo = {}
    if not ids_prof:
        return conteo
    try:
        filas = (
            supabase.table("solicitudes").select("id_profesional")
            .in_("id_profesional", ids_prof).eq("estado", "completado").execute().data
        )
    except Exception:
        return conteo
    for f in filas:
        conteo[f["id_profesional"]] = conteo.get(f["id_profesional"], 0) + 1
    return conteo

def parsear_fecha(valor) -> Optional[datetime]:
    """Convierte fechas ISO de Supabase (con o sin 'Z', con 1 a 6 decimales) a datetime sin zona (UTC)."""
    if not valor:
        return None
    t = str(valor).strip().replace("Z", "+00:00")
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$", t)
    if not m:
        return None
    fraccion = (m.group(3) or "")[:7].ljust(7, "0") if m.group(3) else ""
    try:
        dt = datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}{fraccion}{m.group(4)}")
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = (dt - dt.utcoffset()).replace(tzinfo=None)
    return dt

def conteo_no_leidos(ids_solicitudes: list, id_usuario) -> dict:
    """Cuenta mensajes no leídos (enviados por la otra persona) agrupados por solicitud."""
    conteo = {}
    if not ids_solicitudes:
        return conteo
    res = (
        supabase.table("mensajes")
        .select("id_solicitud")
        .in_("id_solicitud", ids_solicitudes)
        .neq("id_emisor", id_usuario)
        .eq("leido", False)
        .execute()
    )
    for m in res.data:
        conteo[m["id_solicitud"]] = conteo.get(m["id_solicitud"], 0) + 1
    return conteo

def solicitudes_aceptadas_de(usuario: dict) -> list:
    """Solicitudes confirmadas (= chats activos) del usuario, con el nombre de la contraparte."""
    columnas = "id_solicitud, descripcion_problema, id_cliente, id_profesional"

    if usuario["rol"] == "Profesional":
        id_prof = obtener_id_profesional(usuario["id_usuario"])
        if id_prof is None:
            return []
        sols = (
            supabase.table("solicitudes").select(columnas)
            .eq("id_profesional", id_prof).in_("estado", list(ESTADOS_CHAT))
            .order("id_solicitud", desc=True).execute().data
        )
        # La contraparte es el cliente
        for s in sols:
            s["_id_usuario_contacto"] = s["id_cliente"]
    else:
        sols = (
            supabase.table("solicitudes").select(columnas)
            .eq("id_cliente", usuario["id_usuario"]).in_("estado", list(ESTADOS_CHAT))
            .order("id_solicitud", desc=True).execute().data
        )
        # La contraparte es el usuario dueño del perfil profesional
        ids_prof = list({s["id_profesional"] for s in sols})
        mapa_prof = {}
        if ids_prof:
            profs = supabase.table("profesionales").select("id_profesional, id_usuario").in_("id_profesional", ids_prof).execute().data
            mapa_prof = {p["id_profesional"]: p["id_usuario"] for p in profs}
        for s in sols:
            s["_id_usuario_contacto"] = mapa_prof.get(s["id_profesional"])

    ids_contacto = list({s["_id_usuario_contacto"] for s in sols if s["_id_usuario_contacto"] is not None})
    nombres = {}
    if ids_contacto:
        users = supabase.table("usuarios").select("id_usuario, nombre").in_("id_usuario", ids_contacto).execute().data
        nombres = {u["id_usuario"]: u["nombre"] for u in users}

    no_leidos = conteo_no_leidos([s["id_solicitud"] for s in sols], usuario["id_usuario"])

    resultado = []
    for s in sols:
        resultado.append({
            "id_solicitud": s["id_solicitud"],
            "descripcion_problema": s["descripcion_problema"],
            "nombre_contacto": nombres.get(s["_id_usuario_contacto"], "Usuario"),
            "mensajes_sin_leer": no_leidos.get(s["id_solicitud"], 0),
        })
    return resultado

# --- ENDPOINTS ---
@app.post("/registro")
def registrar_usuario(usuario: RegistroUsuario):
    try:
        existing_user = supabase.table("usuarios").select("*").eq("correo", usuario.correo).execute()
        if existing_user.data:
            raise HTTPException(status_code=400, detail="El correo electrónico ya está registrado")

        hashed_password = obtener_password_hash(usuario.contrasena)

        nuevo_usuario = {
            "nombre": usuario.nombre,
            "correo": usuario.correo,
            "telefono": usuario.telefono,
            "contrasena_hash": hashed_password,
            "rol": usuario.rol
        }

        response = supabase.table("usuarios").insert(nuevo_usuario).execute()
        usuario_creado = response.data[0]

        if usuario.rol == 'Profesional':
            nuevo_profesional = {
                "id_usuario": usuario_creado["id_usuario"],
                "oficio": "Sin definir",
                "experiencia_anios": 0,
                "descripcion": "",
                "foto_1": "",
                "foto_2": "",
                "foto_3": ""
            }
            supabase.table("profesionales").insert(nuevo_profesional).execute()

        # No devolver el hash de la contraseña
        usuario_creado.pop("contrasena_hash", None)
        return {"mensaje": "Usuario registrado exitosamente", "usuario": usuario_creado}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al registrar: {str(e)}")

@app.post("/login")
def iniciar_sesion(usuario: LoginUsuario):
    try:
        response = supabase.table("usuarios").select("*").eq("correo", usuario.correo).execute()

        if not response.data:
            raise HTTPException(status_code=400, detail="Correo o contraseña incorrectos")

        user_db = response.data[0]

        if not verificar_contrasena(usuario.contrasena, user_db["contrasena_hash"]):
            raise HTTPException(status_code=400, detail="Correo o contraseña incorrectos")

        access_token_expires = timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
        access_token = crear_token_acceso(
            data={"sub": user_db["correo"], "rol": user_db["rol"]}, expires_delta=access_token_expires
        )

        return {
            "mensaje": "Login exitoso",
            "access_token": access_token,
            "token_type": "bearer",
            "usuario": {
                # FIX: la app necesita el id para saber qué mensajes son "míos"
                "id_usuario": user_db["id_usuario"],
                "nombre": user_db["nombre"],
                "rol": user_db["rol"]
            }
        }
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=500, detail=f"Error en el servidor: {str(e)}")

@app.get("/profesionales/cercanos")
def obtener_profesionales_cercanos(lat: float, lng: float, radio: float = 15.0, busqueda: Optional[str] = None):
    try:
        query = supabase.table("profesionales").select(
            "id_profesional, oficio, latitud, longitud, usuarios(nombre, telefono), descripcion, foto_1, foto_2, foto_3"
        )

        if busqueda:
            query = query.ilike("oficio", f"%{busqueda}%")

        response = query.execute()

        profesionales_cercanos = []
        for prof in response.data:
            if prof.get("latitud") and prof.get("longitud"):
                distancia = calcular_distancia(lat, lng, prof["latitud"], prof["longitud"])
                if distancia <= radio:
                    prof["distancia_km"] = round(distancia, 2)
                    profesionales_cercanos.append(prof)

        profesionales_cercanos.sort(key=lambda x: x["distancia_km"])

        # Calificación promedio y trabajos completados de cada profesional
        ids = [p["id_profesional"] for p in profesionales_cercanos]
        resumen = resumen_calificaciones(ids)
        completados = conteo_completados(ids)
        for p in profesionales_cercanos:
            r = resumen.get(p["id_profesional"])
            p["calificacion_promedio"] = r["promedio"] if r else None
            p["total_resenas"] = r["total"] if r else 0
            p["trabajos_completados"] = completados.get(p["id_profesional"], 0)

        return {"profesionales": profesionales_cercanos}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al buscar profesionales: {str(e)}")

@app.get("/profesionales/oficios")
def listar_oficios():
    return {"oficios": OFICIOS_VALIDOS}

@app.get("/profesionales/perfil")
def obtener_mi_perfil_profesional(usuario_actual: dict = Depends(obtener_usuario_actual)):
    if usuario_actual["rol"] != "Profesional":
        raise HTTPException(status_code=403, detail="Acceso denegado. Solo profesionales.")
    res = supabase.table("profesionales").select(
        "id_profesional, oficio, descripcion, latitud, longitud, foto_1, foto_2, foto_3"
    ).eq("id_usuario", usuario_actual["id_usuario"]).execute()
    if not res.data:
        raise HTTPException(status_code=404, detail="No se encontró el perfil del profesional.")
    prof = res.data[0]
    r = resumen_calificaciones([prof["id_profesional"]]).get(prof["id_profesional"])
    prof["calificacion_promedio"] = r["promedio"] if r else None
    prof["total_resenas"] = r["total"] if r else 0
    prof["trabajos_completados"] = conteo_completados([prof["id_profesional"]]).get(prof["id_profesional"], 0)
    return {"profesional": prof}

@app.put("/profesionales/perfil")
async def actualizar_perfil_profesional(
    descripcion: str = Form(""),
    oficio: Optional[str] = Form(None),
    latitud: Optional[float] = Form(None),
    longitud: Optional[float] = Form(None),
    foto_1: Optional[UploadFile] = File(None),
    foto_2: Optional[UploadFile] = File(None),
    foto_3: Optional[UploadFile] = File(None),
    usuario_actual: dict = Depends(obtener_usuario_actual)
):
    try:
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Acceso denegado. Solo profesionales.")

        id_usuario = usuario_actual["id_usuario"]
        datos_actualizar = {"descripcion": descripcion}

        if oficio:
            if oficio not in OFICIOS_VALIDOS:
                raise HTTPException(status_code=400, detail="Oficio no válido.")
            datos_actualizar["oficio"] = oficio

        if latitud is not None or longitud is not None:
            if latitud is None or longitud is None:
                raise HTTPException(status_code=400, detail="Debes enviar latitud y longitud juntas.")
            if not (-90 <= latitud <= 90 and -180 <= longitud <= 180):
                raise HTTPException(status_code=400, detail="Ubicación fuera de rango.")
            datos_actualizar["latitud"] = latitud
            datos_actualizar["longitud"] = longitud

        fotos_recibidas = {"foto_1": foto_1, "foto_2": foto_2, "foto_3": foto_3}

        for campo, archivo in fotos_recibidas.items():
            if archivo and archivo.filename:
                contenido = await archivo.read()
                extension = archivo.filename.split(".")[-1] if "." in archivo.filename else "jpg"
                nombre_archivo = f"profesionales/user_{id_usuario}_{campo}.{extension}"

                supabase.storage.from_("trabajos").upload(
                    path=nombre_archivo,
                    file=contenido,
                    file_options={
                        "content-type": archivo.content_type or "image/jpeg",
                        "upsert": "true"
                    }
                )

                url_publica = supabase.storage.from_("trabajos").get_public_url(nombre_archivo)
                datos_actualizar[campo] = url_publica

        response = supabase.table("profesionales").update(datos_actualizar).eq("id_usuario", id_usuario).execute()

        if not response.data:
            raise HTTPException(status_code=404, detail="No se encontró el perfil del profesional.")

        return {"mensaje": "Perfil e imágenes actualizadas correctamente", "profesional": response.data[0]}
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=400, detail=f"Error al actualizar perfil: {str(e)}")

# --- ENDPOINTS DE SOLICITUDES ---
@app.post("/solicitudes")
def crear_solicitud(
    solicitud: CrearSolicitud,
    usuario_actual: dict = Depends(obtener_usuario_actual),
):
    try:
        # Convertimos a entero si viene como texto numérico desde la app
        if isinstance(solicitud.id_profesional, str) and solicitud.id_profesional.isdigit():
            id_prof = int(solicitud.id_profesional)
        else:
            id_prof = solicitud.id_profesional

        nueva_solicitud = {
            "id_cliente": usuario_actual["id_usuario"],
            "id_profesional": id_prof,
            "descripcion_problema": solicitud.descripcion_problema,
            "direccion_texto": solicitud.direccion_texto,
            "latitud": solicitud.latitud,
            "longitud": solicitud.longitud,
            "estado": "pendiente",
        }

        response = supabase.table("solicitudes").insert(nueva_solicitud).execute()
        return {
            "mensaje": "Solicitud enviada con éxito",
            "solicitud": response.data[0],
        }
    except Exception as e:
        print("Error en Supabase:", e)
        raise HTTPException(status_code=400, detail=f"Error al crear solicitud: {str(e)}")

@app.get("/solicitudes/pendientes")
def obtener_solicitudes_pendientes(usuario_actual: dict = Depends(obtener_usuario_actual)):
    try:
        id_profesional = obtener_id_profesional(usuario_actual["id_usuario"])
        if id_profesional is None:
            raise HTTPException(status_code=404, detail="Perfil profesional no encontrado")

        response = supabase.table("solicitudes").select(
            "id_solicitud, descripcion_problema, direccion_texto, latitud, longitud, estado, fecha_creacion, "
            "precio_cotizacion, detalle_cotizacion, usuarios!id_cliente(nombre, telefono)"
        ).eq("id_profesional", id_profesional).in_(
            "estado", ["pendiente", "aceptado", "cotizacion_rechazada", "cotizado"]
        ).order("fecha_creacion", desc=True).execute()

        return {"solicitudes": response.data}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar solicitudes: {str(e)}")

@app.get("/solicitudes/activas")
def obtener_solicitudes_activas(usuario_actual: dict = Depends(obtener_usuario_actual)):
    """Lista de chats: solicitudes aceptadas del usuario (cliente o profesional)."""
    try:
        return {"solicitudes": solicitudes_aceptadas_de(usuario_actual)}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar chats: {str(e)}")

@app.put("/solicitudes/{id_solicitud}/estado")
def cambiar_estado_solicitud(
    id_solicitud: int,
    datos: CambiarEstadoSolicitud,
    usuario_actual: dict = Depends(obtener_usuario_actual),
):
    try:
        if datos.estado not in ["aceptado", "rechazado"]:
            raise HTTPException(status_code=400, detail="Estado no válido")
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Solo el profesional puede responder solicitudes")

        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] != "pendiente":
            raise HTTPException(status_code=400, detail="La solicitud ya fue respondida")

        response = supabase.table("solicitudes").update({"estado": datos.estado}).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": f"Solicitud {datos.estado}", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al actualizar estado: {str(e)}")

@app.post("/solicitudes/{id_solicitud}/cotizacion")
def enviar_cotizacion(
    id_solicitud: int,
    datos: CrearCotizacion,
    usuario_actual: dict = Depends(obtener_usuario_actual),
):
    """El profesional envía (o reenvía) su cotización de una solicitud que ya aceptó."""
    try:
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Solo el profesional puede enviar cotizaciones")

        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] not in ("aceptado", "cotizacion_rechazada"):
            raise HTTPException(status_code=400, detail="Solo puedes cotizar solicitudes que ya aceptaste y que no tengan una cotización pendiente")

        if not math.isfinite(datos.precio) or datos.precio <= 0 or datos.precio > 1_000_000:
            raise HTTPException(status_code=400, detail="El precio debe ser mayor a 0 y menor o igual a 1,000,000")

        response = supabase.table("solicitudes").update({
            "precio_cotizacion": round(datos.precio, 2),
            "detalle_cotizacion": (datos.detalle or "").strip(),
            "estado": "cotizado",
        }).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": "Cotización enviada", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al enviar la cotización: {str(e)}")

@app.put("/solicitudes/{id_solicitud}/cotizacion")
def responder_cotizacion(
    id_solicitud: int,
    datos: ResponderCotizacion,
    usuario_actual: dict = Depends(obtener_usuario_actual),
):
    """El cliente acepta o rechaza la cotización. Al aceptar se habilita el chat."""
    try:
        sol = verificar_participante(id_solicitud, usuario_actual)
        if str(sol["id_cliente"]) != str(usuario_actual["id_usuario"]):
            raise HTTPException(status_code=403, detail="Solo el cliente puede responder la cotización")
        if sol["estado"] != "cotizado":
            raise HTTPException(status_code=400, detail="No hay una cotización pendiente de respuesta")

        nuevo_estado = "confirmado" if datos.aceptar else "cotizacion_rechazada"
        response = supabase.table("solicitudes").update({"estado": nuevo_estado}).eq("id_solicitud", id_solicitud).execute()
        return {
            "mensaje": "Cotización aceptada. Ya pueden chatear" if datos.aceptar else "Cotización rechazada",
            "solicitud": response.data[0],
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al responder la cotización: {str(e)}")

@app.get("/solicitudes/mias")
def obtener_mis_solicitudes(usuario_actual: dict = Depends(obtener_usuario_actual)):
    """Solicitudes que envió el cliente, con el estado, la cotización y los datos del profesional."""
    try:
        sols = (
            supabase.table("solicitudes")
            .select("id_solicitud, descripcion_problema, direccion_texto, estado, precio_cotizacion, detalle_cotizacion, id_profesional, "
                    "fecha_inicio, fecha_fin, fecha_completado, nota_cierre, motivo_rechazo_cierre, "
                    "precio_propuesto, detalle_propuesto, precio_original, ajuste_respuesta")
            .eq("id_cliente", usuario_actual["id_usuario"])
            .order("id_solicitud", desc=True)
            .limit(50)
            .execute().data
        )

        info = {}
        ids_prof = list({s["id_profesional"] for s in sols})
        if ids_prof:
            profs = supabase.table("profesionales").select("id_profesional, oficio, id_usuario").in_("id_profesional", ids_prof).execute().data
            ids_users = list({p["id_usuario"] for p in profs})
            users = supabase.table("usuarios").select("id_usuario, nombre").in_("id_usuario", ids_users).execute().data if ids_users else []
            nombres = {u["id_usuario"]: u["nombre"] for u in users}
            info = {p["id_profesional"]: {"oficio": p.get("oficio", ""), "nombre": nombres.get(p["id_usuario"], "Profesional")} for p in profs}

        # Reseña que el cliente dejó en los trabajos completados
        resenas = {}
        ids_completadas = [s["id_solicitud"] for s in sols if s["estado"] == "completado"]
        if ids_completadas:
            try:
                filas = supabase.table("resenas").select("id_solicitud, calificacion, comentario, foto_url").in_("id_solicitud", ids_completadas).execute().data
                resenas = {f["id_solicitud"]: f for f in filas}
            except Exception:
                resenas = {}

        for s in sols:
            datos = info.get(s["id_profesional"], {})
            s["nombre_profesional"] = datos.get("nombre", "Profesional")
            s["oficio"] = datos.get("oficio", "")
            s["resena"] = resenas.get(s["id_solicitud"])
        return {"solicitudes": sols}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar tus solicitudes: {str(e)}")

# --- EJECUCIÓN DEL TRABAJO: iniciar, terminar, verificar y calificar ---
@app.put("/solicitudes/{id_solicitud}/iniciar")
def iniciar_trabajo(id_solicitud: int, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """El profesional marca que comenzó el trabajo (solo si el cliente ya aceptó la cotización)."""
    try:
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Solo el profesional puede iniciar el trabajo")
        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] != "confirmado":
            raise HTTPException(status_code=400, detail="Solo puedes iniciar trabajos cuya cotización ya fue aceptada por el cliente")

        response = supabase.table("solicitudes").update({
            "estado": "en_curso",
            "fecha_inicio": ahora_iso(),
        }).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": "Trabajo iniciado", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al iniciar el trabajo: {str(e)}")

@app.put("/solicitudes/{id_solicitud}/terminar")
def terminar_trabajo(id_solicitud: int, datos: TerminarTrabajo, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """El profesional marca el trabajo como terminado; queda pendiente de que el cliente lo verifique."""
    try:
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Solo el profesional puede marcar el trabajo como terminado")
        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] != "en_curso":
            raise HTTPException(status_code=400, detail="Solo puedes terminar un trabajo que ya iniciaste")

        response = supabase.table("solicitudes").update({
            "estado": "por_verificar",
            "fecha_fin": ahora_iso(),
            "nota_cierre": (datos.nota or "").strip()[:1000],
            "motivo_rechazo_cierre": None,
        }).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": "Trabajo marcado como terminado. Esperando la verificación del cliente", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al terminar el trabajo: {str(e)}")

@app.put("/solicitudes/{id_solicitud}/ajuste")
def proponer_ajuste(id_solicitud: int, datos: ProponerAjuste, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """El profesional propone un nuevo precio. El cliente debe aceptarlo para continuar el trabajo."""
    try:
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Solo el profesional puede modificar la cotización")
        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] not in ("confirmado", "en_curso"):
            raise HTTPException(status_code=400, detail="Solo puedes modificar la cotización de un trabajo confirmado o en curso")

        if not math.isfinite(datos.precio) or datos.precio <= 0 or datos.precio > 1_000_000:
            raise HTTPException(status_code=400, detail="El precio debe ser mayor a 0 y menor o igual a 1,000,000")
        precio = round(datos.precio, 2)
        if sol.get("precio_cotizacion") is not None and abs(float(sol["precio_cotizacion"]) - precio) < 0.005:
            raise HTTPException(status_code=400, detail="El nuevo precio es igual al actual")
        motivo = (datos.motivo or "").strip()
        if len(motivo) < 3:
            raise HTTPException(status_code=400, detail="Explica al cliente por qué cambia el precio")

        response = supabase.table("solicitudes").update({
            "estado": "ajuste_pendiente",
            "estado_previo_ajuste": sol["estado"],
            "precio_propuesto": precio,
            "detalle_propuesto": motivo[:1000],
            "precio_original": sol.get("precio_original") if sol.get("precio_original") is not None else sol.get("precio_cotizacion"),
            "ajuste_respuesta": None,
        }).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": "Propuesta enviada. Esperando la respuesta del cliente", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al proponer el ajuste: {str(e)}")

@app.put("/solicitudes/{id_solicitud}/ajuste/respuesta")
def responder_ajuste(id_solicitud: int, datos: ResponderAjuste, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """El cliente acepta o rechaza el nuevo precio. El trabajo vuelve al estado en que estaba."""
    try:
        sol = verificar_participante(id_solicitud, usuario_actual)
        if str(sol["id_cliente"]) != str(usuario_actual["id_usuario"]):
            raise HTTPException(status_code=403, detail="Solo el cliente puede responder el cambio de precio")
        if sol["estado"] != "ajuste_pendiente":
            raise HTTPException(status_code=400, detail="No hay un cambio de precio pendiente de respuesta")

        previo = sol.get("estado_previo_ajuste")
        if previo not in ("confirmado", "en_curso"):
            previo = "en_curso" if sol.get("fecha_inicio") else "confirmado"

        cambios = {
            "estado": previo,
            "estado_previo_ajuste": None,
            "ajuste_respuesta": "aceptado" if datos.aceptar else "rechazado",
        }
        if datos.aceptar:
            cambios["precio_cotizacion"] = sol["precio_propuesto"]
        response = supabase.table("solicitudes").update(cambios).eq("id_solicitud", id_solicitud).execute()
        return {
            "mensaje": "Nuevo precio aceptado" if datos.aceptar else "Nuevo precio rechazado. Se mantiene el precio original",
            "solicitud": response.data[0],
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al responder el cambio de precio: {str(e)}")

@app.put("/solicitudes/{id_solicitud}/cierre-rechazado")
def rechazar_cierre(id_solicitud: int, datos: RechazarCierre, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """El cliente indica que el trabajo aún no está terminado: vuelve a 'en_curso' con el motivo."""
    try:
        sol = verificar_participante(id_solicitud, usuario_actual)
        if str(sol["id_cliente"]) != str(usuario_actual["id_usuario"]):
            raise HTTPException(status_code=403, detail="Solo el cliente puede verificar el trabajo")
        if sol["estado"] != "por_verificar":
            raise HTTPException(status_code=400, detail="El profesional aún no ha marcado el trabajo como terminado")

        motivo = (datos.motivo or "").strip()
        if len(motivo) < 3:
            raise HTTPException(status_code=400, detail="Cuéntale al profesional qué falta por terminar")

        response = supabase.table("solicitudes").update({
            "estado": "en_curso",
            "motivo_rechazo_cierre": motivo[:1000],
        }).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": "Se avisó al profesional que el trabajo aún no está terminado", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al rechazar el cierre: {str(e)}")

@app.post("/solicitudes/{id_solicitud}/resena")
async def calificar_trabajo(
    id_solicitud: int,
    calificacion: int = Form(...),
    comentario: str = Form(""),
    foto: Optional[UploadFile] = File(None),
    usuario_actual: dict = Depends(obtener_usuario_actual),
):
    """El cliente confirma que el trabajo quedó terminado y lo califica (comentario y foto opcionales)."""
    try:
        sol = verificar_participante(id_solicitud, usuario_actual)
        if str(sol["id_cliente"]) != str(usuario_actual["id_usuario"]):
            raise HTTPException(status_code=403, detail="Solo el cliente puede calificar el trabajo")
        if sol["estado"] != "por_verificar":
            raise HTTPException(status_code=400, detail="El profesional aún no ha marcado el trabajo como terminado, o ya fue calificado")
        if not (1 <= calificacion <= 5):
            raise HTTPException(status_code=400, detail="La calificación debe ser de 1 a 5 estrellas")

        foto_url = ""
        if foto and foto.filename:
            extension = foto.filename.rsplit(".", 1)[-1].lower() if "." in foto.filename else "jpg"
            if extension not in ("jpg", "jpeg", "png", "webp"):
                raise HTTPException(status_code=400, detail="La foto debe ser JPG, PNG o WEBP")
            contenido = await foto.read()
            if len(contenido) > 5 * 1024 * 1024:
                raise HTTPException(status_code=400, detail="La foto no puede pesar más de 5 MB")
            nombre_archivo = f"resenas/solicitud_{id_solicitud}.{extension}"
            supabase.storage.from_("trabajos").upload(
                path=nombre_archivo,
                file=contenido,
                file_options={"content-type": foto.content_type or "image/jpeg", "upsert": "true"},
            )
            foto_url = supabase.storage.from_("trabajos").get_public_url(nombre_archivo)

        # upsert: si un intento anterior guardó la reseña pero falló al cerrar el trabajo, se puede reintentar
        supabase.table("resenas").upsert({
            "id_solicitud": id_solicitud,
            "id_cliente": sol["id_cliente"],
            "id_profesional": sol["id_profesional"],
            "calificacion": calificacion,
            "comentario": (comentario or "").strip()[:1000],
            "foto_url": foto_url,
        }, on_conflict="id_solicitud").execute()

        response = supabase.table("solicitudes").update({
            "estado": "completado",
            "fecha_completado": ahora_iso(),
        }).eq("id_solicitud", id_solicitud).execute()
        return {"mensaje": "¡Gracias! Trabajo confirmado y calificado", "solicitud": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al calificar el trabajo: {str(e)}")

@app.get("/solicitudes/{id_solicitud}/resena")
def obtener_resena(id_solicitud: int, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """Reseña de un trabajo (la pueden ver el cliente y el profesional de esa solicitud)."""
    try:
        verificar_participante(id_solicitud, usuario_actual)
        res = supabase.table("resenas").select("*").eq("id_solicitud", id_solicitud).execute()
        return {"resena": res.data[0] if res.data else None}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar la reseña: {str(e)}")

@app.get("/profesionales/ganancias")
def ganancias_profesional(usuario_actual: dict = Depends(obtener_usuario_actual)):
    """Resumen de ganancias del profesional: solo cuentan los trabajos completados (verificados por el cliente)."""
    try:
        if usuario_actual["rol"] != "Profesional":
            raise HTTPException(status_code=403, detail="Solo los profesionales tienen ganancias")
        id_profesional = obtener_id_profesional(usuario_actual["id_usuario"])
        if id_profesional is None:
            raise HTTPException(status_code=404, detail="Perfil profesional no encontrado")

        filas = (
            supabase.table("solicitudes")
            .select("id_solicitud, descripcion_problema, precio_cotizacion, fecha_inicio, fecha_fin, fecha_completado, usuarios!id_cliente(nombre)")
            .eq("id_profesional", id_profesional)
            .eq("estado", "completado")
            .order("fecha_completado", desc=True)
            .execute().data
        )

        total = 0.0
        segundos_totales = 0
        trabajos = []
        for f in filas:
            precio = float(f.get("precio_cotizacion") or 0)
            ini, fin = parsear_fecha(f.get("fecha_inicio")), parsear_fecha(f.get("fecha_fin"))
            segundos = int((fin - ini).total_seconds()) if ini and fin and fin > ini else 0
            total += precio
            segundos_totales += segundos
            trabajos.append({
                "id_solicitud": f["id_solicitud"],
                "descripcion_problema": f.get("descripcion_problema") or "",
                "cliente": (f.get("usuarios") or {}).get("nombre", "Cliente"),
                "monto": round(precio, 2),
                "segundos_trabajados": segundos,
                "fecha_completado": f.get("fecha_completado"),
            })

        return {
            "resumen": {
                "total_ganado": round(total, 2),
                "trabajos_completados": len(trabajos),
                "segundos_trabajados": segundos_totales,
            },
            "trabajos": trabajos,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar las ganancias: {str(e)}")

@app.get("/profesionales/{id_profesional}/resenas")
def resenas_de_profesional(id_profesional: str, usuario_actual: dict = Depends(obtener_usuario_actual)):
    """Reseñas públicas de un profesional (nombre del cliente abreviado) y su calificación promedio."""
    try:
        resumen = resumen_calificaciones([id_profesional]).get(id_profesional, {"promedio": None, "total": 0})
        completados = conteo_completados([id_profesional]).get(id_profesional, 0)

        filas = (
            supabase.table("resenas")
            .select("id_resena, id_cliente, calificacion, comentario, foto_url, fecha_creacion")
            .eq("id_profesional", id_profesional)
            .order("id_resena", desc=True)
            .limit(30)
            .execute().data
        )
        ids_clientes = list({f["id_cliente"] for f in filas})
        nombres = {}
        if ids_clientes:
            users = supabase.table("usuarios").select("id_usuario, nombre").in_("id_usuario", ids_clientes).execute().data
            nombres = {u["id_usuario"]: u["nombre"] for u in users}

        resenas = [{
            "calificacion": f["calificacion"],
            "comentario": f.get("comentario") or "",
            "foto_url": f.get("foto_url") or "",
            "fecha_creacion": f.get("fecha_creacion"),
            "nombre_cliente": nombre_corto(nombres.get(f["id_cliente"], "")),
        } for f in filas]

        return {
            "resumen": {"promedio": resumen["promedio"], "total": resumen["total"], "trabajos_completados": completados},
            "resenas": resenas,
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar las reseñas: {str(e)}")

@app.get("/solicitudes/trabajos")
def obtener_trabajos_profesional(usuario_actual: dict = Depends(obtener_usuario_actual)):
    """Trabajos del profesional ya confirmados por el cliente (por iniciar, en curso, por verificar y completados)."""
    try:
        id_profesional = obtener_id_profesional(usuario_actual["id_usuario"])
        if id_profesional is None:
            raise HTTPException(status_code=404, detail="Perfil profesional no encontrado")

        trabajos = (
            supabase.table("solicitudes").select(
                "id_solicitud, descripcion_problema, direccion_texto, latitud, longitud, estado, fecha_creacion, "
                "precio_cotizacion, detalle_cotizacion, fecha_inicio, fecha_fin, fecha_completado, nota_cierre, "
                "motivo_rechazo_cierre, precio_propuesto, detalle_propuesto, precio_original, ajuste_respuesta, usuarios!id_cliente(nombre, telefono)"
            )
            .eq("id_profesional", id_profesional)
            .in_("estado", ["confirmado", "en_curso", "por_verificar", "ajuste_pendiente", "completado"])
            .order("id_solicitud", desc=True)
            .limit(100)
            .execute().data
        )

        resenas = {}
        ids_completados = [t["id_solicitud"] for t in trabajos if t["estado"] == "completado"]
        if ids_completados:
            try:
                filas = supabase.table("resenas").select("id_solicitud, calificacion, comentario, foto_url").in_("id_solicitud", ids_completados).execute().data
                resenas = {f["id_solicitud"]: f for f in filas}
            except Exception:
                resenas = {}
        for t in trabajos:
            t["resena"] = resenas.get(t["id_solicitud"])

        return {"solicitudes": trabajos}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar tus trabajos: {str(e)}")

# --- NOTIFICACIONES (círculos rojos) ---

@app.get("/notificaciones/resumen")
def resumen_notificaciones(usuario_actual: dict = Depends(obtener_usuario_actual)):
    try:
        chats = solicitudes_aceptadas_de(usuario_actual)
        mensajes_sin_leer = sum(c["mensajes_sin_leer"] for c in chats)

        solicitudes_pendientes = 0
        if usuario_actual["rol"] == "Profesional":
            id_prof = obtener_id_profesional(usuario_actual["id_usuario"])
            if id_prof is not None:
                # Lo que necesita acción del profesional: solicitudes nuevas y cotizaciones por enviar
                pend = (
                    supabase.table("solicitudes").select("id_solicitud")
                    .eq("id_profesional", id_prof)
                    .in_("estado", ["pendiente", "aceptado", "cotizacion_rechazada"]).execute()
                )
                solicitudes_pendientes = len(pend.data)

        # Cotizaciones que el cliente todavía no responde
        cotizaciones_pendientes = 0
        if usuario_actual["rol"] != "Profesional":
            cot = (
                supabase.table("solicitudes").select("id_solicitud")
                .eq("id_cliente", usuario_actual["id_usuario"]).eq("estado", "cotizado").execute()
            )
            cotizaciones_pendientes = len(cot.data)

        # Trabajos terminados por el profesional que el cliente aún debe verificar
        cierres_pendientes = 0
        if usuario_actual["rol"] != "Profesional":
            cier = (
                supabase.table("solicitudes").select("id_solicitud")
                .eq("id_cliente", usuario_actual["id_usuario"]).eq("estado", "por_verificar").execute()
            )
            cierres_pendientes = len(cier.data)

        # Cambios de precio propuestos por el profesional que el cliente debe responder
        ajustes_pendientes = 0
        if usuario_actual["rol"] != "Profesional":
            aj = (
                supabase.table("solicitudes").select("id_solicitud")
                .eq("id_cliente", usuario_actual["id_usuario"]).eq("estado", "ajuste_pendiente").execute()
            )
            ajustes_pendientes = len(aj.data)

        # Trabajos confirmados que el profesional todavía no inicia
        trabajos_por_iniciar = 0
        if usuario_actual["rol"] == "Profesional":
            id_prof = obtener_id_profesional(usuario_actual["id_usuario"])
            if id_prof is not None:
                ini = (
                    supabase.table("solicitudes").select("id_solicitud")
                    .eq("id_profesional", id_prof).eq("estado", "confirmado").execute()
                )
                trabajos_por_iniciar = len(ini.data)

        return {
            "mensajes_sin_leer": mensajes_sin_leer,
            "solicitudes_pendientes": solicitudes_pendientes,
            "cotizaciones_pendientes": cotizaciones_pendientes,
            "cierres_pendientes": cierres_pendientes,
            "ajustes_pendientes": ajustes_pendientes,
            "trabajos_por_iniciar": trabajos_por_iniciar,
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar notificaciones: {str(e)}")

# --- MENSAJES ---
@app.post("/solicitudes/{id_solicitud}/mensajes")
def enviar_mensaje(id_solicitud: int, mensaje: CrearMensaje, usuario_actual: dict = Depends(obtener_usuario_actual)):
    try:
        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] not in ESTADOS_CHAT:
            raise HTTPException(status_code=403, detail="El chat está disponible mientras el trabajo está activo (desde que el cliente acepta la cotización)")

        contenido = mensaje.contenido.strip()
        if not contenido:
            raise HTTPException(status_code=400, detail="El mensaje está vacío")

        nuevo_mensaje = {
            "id_solicitud": id_solicitud,
            "id_emisor": usuario_actual["id_usuario"],
            "contenido": contenido,
            "leido": False,
        }
        response = supabase.table("mensajes").insert(nuevo_mensaje).execute()
        return {"mensaje": "Mensaje enviado", "data": response.data[0]}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al enviar mensaje: {str(e)}")

@app.get("/solicitudes/{id_solicitud}/mensajes")
def obtener_mensajes(id_solicitud: int, usuario_actual: dict = Depends(obtener_usuario_actual)):
    try:
        verificar_participante(id_solicitud, usuario_actual)

        response = (
            supabase.table("mensajes").select("*")
            .eq("id_solicitud", id_solicitud)
            .order("fecha_envio", desc=False)
            .execute()
        )

        # Al abrir el chat, marcamos como leídos los mensajes de la otra persona
        pendientes = [
            m for m in response.data
            if str(m["id_emisor"]) != str(usuario_actual["id_usuario"]) and not m.get("leido")
        ]
        if pendientes:
            (
                supabase.table("mensajes").update({"leido": True})
                .eq("id_solicitud", id_solicitud)
                .neq("id_emisor", usuario_actual["id_usuario"])
                .eq("leido", False)
                .execute()
            )

        return {"mensajes": response.data}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al obtener mensajes: {str(e)}")