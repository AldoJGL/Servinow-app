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
import uuid

# 1. Configuración de Supabase
SUPABASE_URL = "https://gruuoelmqzvjwdcluudz.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo"
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# 2. Configuración de Seguridad (JWT y Passlib)
SECRET_KEY = "super-clave-secreta-de-servinow-cambiar-en-produccion"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

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
    R = 6371.0 # Radio de la Tierra en kilómetros
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

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
        
        return {"mensaje": "Usuario registrado exitosamente", "usuario": usuario_creado}
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

@app.put("/profesionales/perfil")
async def actualizar_perfil_profesional(
    descripcion: str = Form(""),
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

        fotos_recibidas = {"foto_1": foto_1, "foto_2": foto_2, "foto_3": foto_3}

        for campo, archivo in fotos_recibidas.items():
            if archivo and archivo.filename:
                # Leer bytes del archivo enviado desde Flutter
                contenido = await archivo.read()
                extension = archivo.filename.split(".")[-1] if "." in archivo.filename else "jpg"
                nombre_archivo = f"profesionales/user_{id_usuario}_{campo}.{extension}"

                # Subir archivo al bucket "trabajos" en Supabase Storage
                supabase.storage.from_("trabajos").upload(
                    path=nombre_archivo,
                    file=contenido,
                    file_options={
                        "content-type": archivo.content_type or "image/jpeg",
                        "upsert": "true"  # Reemplaza el archivo si ya existe
                    }
                )

                # Generar y guardar la URL pública completa de la imagen
                url_publica = supabase.storage.from_("trabajos").get_public_url(nombre_archivo)
                datos_actualizar[campo] = url_publica

        # Actualizar la base de datos
        response = supabase.table("profesionales").update(datos_actualizar).eq("id_usuario", id_usuario).execute()

        if not response.data:
            raise HTTPException(status_code=404, detail="No se encontró el perfil del profesional.")

        return {"mensaje": "Perfil e imágenes actualizadas correctamente", "profesional": response.data[0]}
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=400, detail=f"Error al actualizar perfil: {str(e)}")