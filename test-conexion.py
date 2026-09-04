from supabase import create_client, Client

url: str = "https://gruuoelmqzvjwdcluudz.supabase.co"
key: str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdydXVvZWxtcXp2andkY2x1dWR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxOTA1MjIsImV4cCI6MjEwMzc2NjUyMn0.DhV3qJAdYIc5Pt7xzx3qICeFa42F-lXAEuyHSS7o7Jo"
supabase: Client = create_client(url, key)

nuevo_usuario = {
    "nombre": "Usuario Prueba",
    "correo": "prueba@servinow.com",
    "telefono": "8123456789",
    "contrasena_hash": "hash_falso_123",
    "rol": "Cliente"
}

try:
    respuesta = supabase.table("usuarios").insert(nuevo_usuario).execute()
    print("¡Conexión exitosa! Usuario insertado:")
    print(respuesta.data)
except Exception as e:
    print(f"Error al conectar o insertar: {e}")