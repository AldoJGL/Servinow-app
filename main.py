from fastapi import FastAPI
from pydantic import BaseModel
from supabase import create_client, Client

app = FastAPI()

# Pega aquí tus credenciales exactas
url: str = "https://gruuoelmqzvjwdcluudz.supabase.co"
key: str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo"
supabase: Client = create_client(url, key)

# Definimos la estructura de datos que esperamos recibir de Flutter
class UsuarioNuevo(BaseModel):
    nombre: str
    correo: str
    telefono: str
    contrasena_hash: str
    rol: str

# Creamos la ruta para que la app móvil nos mande información
@app.post("/registro")
def registrar_usuario(usuario: UsuarioNuevo):
    try:
        # usuario.dict() convierte los datos recibidos al formato que entiende Supabase
        respuesta = supabase.table("usuarios").insert(usuario.dict()).execute()
        return {"mensaje": "Usuario creado exitosamente", "datos": respuesta.data}
    except Exception as e:
        return {"error": str(e)}