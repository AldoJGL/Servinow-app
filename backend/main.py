from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from supabase import create_client, Client
from passlib.context import CryptContext

# 1. Configurar el motor de encriptación
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

app = FastAPI()

# 2. Conexión a Supabase (¡Pon tus credenciales reales aquí!)
url = "https://gruuoelmqzvjwdcluudz.supabase.co"
key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo"
supabase: Client = create_client(url, key)

# 3. Modelos de datos
class UsuarioNuevo(BaseModel):
    nombre: str
    correo: str
    telefono: str
    contrasena: str  # El usuario envía su contraseña normal
    rol: str

class UsuarioLogin(BaseModel):
    correo: str
    contrasena: str

# 4. Endpoint de Registro Seguro
@app.post("/registro")
def registrar_usuario(usuario: UsuarioNuevo):
    # Generar el hash (texto encriptado) de la contraseña
    hash_generado = pwd_context.hash(usuario.contrasena)
    
    datos_insertar = {
        "nombre": usuario.nombre,
        "correo": usuario.correo,
        "telefono": usuario.telefono,
        "contrasena_hash": hash_generado,
        "rol": usuario.rol
    }
    
    try:
        respuesta = supabase.table("usuarios").insert(datos_insertar).execute()
        return {"mensaje": "Usuario creado exitosamente", "id": respuesta.data[0]["id_usuario"]}
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Error al registrar: {str(e)}")

# 5. Nuevo Endpoint de Login
@app.post("/login")
def iniciar_sesion(credenciales: UsuarioLogin):
    # Buscar si existe un registro con ese correo
    respuesta = supabase.table("usuarios").select("*").eq("correo", credenciales.correo).execute()
    
    # Si la lista de datos viene vacía, el correo no existe
    if not respuesta.data:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
        
    usuario_db = respuesta.data[0]
    
    # Verificar si la contraseña ingresada coincide con el hash guardado
    contrasena_valida = pwd_context.verify(credenciales.contrasena, usuario_db["contrasena_hash"])
    
    if not contrasena_valida:
        raise HTTPException(status_code=401, detail="Contraseña incorrecta")
        
    return {
        "mensaje": "Login exitoso", 
        "usuario": {
            "nombre": usuario_db["nombre"], 
            "rol": usuario_db["rol"]
        }
    }