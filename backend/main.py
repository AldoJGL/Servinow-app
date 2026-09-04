from fastapi import FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, EmailStr
from supabase import create_client, Client
from passlib.context import CryptContext
from datetime import datetime, timedelta
from jose import jwt

# 1. Configuración de Supabase
SUPABASE_URL = "https://gruuoelmqzvjwdcluudz.supabase.co"  # Mantén tus credenciales anteriores
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo"
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# 2. Configuración de Seguridad (JWT y Passlib)
SECRET_KEY = "super-clave-secreta-de-servinow-cambiar-en-produccion"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

app = FastAPI()

# 3. Configuración de CORS para permitir conexiones desde Flutter Web
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

# --- FUNCIONES AUXILIARES ---
def verificar_contrasena(plain_password, hashed_password):
    return pwd_context.verify(plain_password, hashed_password)

def obtener_password_hash(password):
    return pwd_context.hash(password)

def crear_token_acceso(data: dict, expires_delta: timedelta | None = None):
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + timedelta(minutes=15)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

# --- ENDPOINTS ---
@app.post("/registro")
def registrar_usuario(usuario: RegistroUsuario):
    try:
        # Verificar si el correo ya existe
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
        
        return {"mensaje": "Usuario registrado exitosamente", "usuario": response.data}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al registrar: {str(e)}")

@app.post("/login")
def iniciar_sesion(usuario: LoginUsuario):
    try:
        # Buscar usuario por correo
        response = supabase.table("usuarios").select("*").eq("correo", usuario.correo).execute()
        
        if not response.data:
            raise HTTPException(status_code=400, detail="Correo o contraseña incorrectos")

        user_db = response.data[0]

        # Verificar contraseña encriptada
        if not verificar_contrasena(usuario.contrasena, user_db["contrasena_hash"]):
            raise HTTPException(status_code=400, detail="Correo o contraseña incorrectos")

        # Generar el Token JWT de acceso
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