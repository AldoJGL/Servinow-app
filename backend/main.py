from fastapi import FastAPI, HTTPException, status, Depends, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel, EmailStr
from supabase import create_client, Client
from passlib.context import CryptContext
from datetime import datetime, timedelta
from jose import JWTError, jwt
import math
from typing import Optional

# 1. Configuración de Supabase
SUPABASE_URL = "https://gruuoelmqzvjwdcluudz.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo"
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# 2. Configuración de Seguridad (JWT y Passlib)
SECRET_KEY = "super-clave-secreta-de-servinow-cambiar-en-produccion"
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
    """Solicitudes aceptadas (= chats activos) del usuario, con el nombre de la contraparte."""
    columnas = "id_solicitud, descripcion_problema, id_cliente, id_profesional"

    if usuario["rol"] == "Profesional":
        id_prof = obtener_id_profesional(usuario["id_usuario"])
        if id_prof is None:
            return []
        sols = (
            supabase.table("solicitudes").select(columnas)
            .eq("id_profesional", id_prof).eq("estado", "aceptado")
            .order("id_solicitud", desc=True).execute().data
        )
        # La contraparte es el cliente
        for s in sols:
            s["_id_usuario_contacto"] = s["id_cliente"]
    else:
        sols = (
            supabase.table("solicitudes").select(columnas)
            .eq("id_cliente", usuario["id_usuario"]).eq("estado", "aceptado")
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
    return {"profesional": res.data[0]}

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
            "id_solicitud, descripcion_problema, direccion_texto, latitud, longitud, estado, fecha_creacion, usuarios!id_cliente(nombre, telefono)"
        ).eq("id_profesional", id_profesional).eq("estado", "pendiente").execute()

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
                pend = (
                    supabase.table("solicitudes").select("id_solicitud")
                    .eq("id_profesional", id_prof).eq("estado", "pendiente").execute()
                )
                solicitudes_pendientes = len(pend.data)

        return {
            "mensajes_sin_leer": mensajes_sin_leer,
            "solicitudes_pendientes": solicitudes_pendientes,
        }
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al consultar notificaciones: {str(e)}")

# --- MENSAJES ---
@app.post("/solicitudes/{id_solicitud}/mensajes")
def enviar_mensaje(id_solicitud: int, mensaje: CrearMensaje, usuario_actual: dict = Depends(obtener_usuario_actual)):
    try:
        sol = verificar_participante(id_solicitud, usuario_actual)
        if sol["estado"] != "aceptado":
            raise HTTPException(status_code=403, detail="El chat se habilita cuando el profesional acepta la solicitud")

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