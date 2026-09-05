import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  runApp(const ServiNowApp());
}

class ServiNowApp extends StatelessWidget {
  const ServiNowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ServiNow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}

// --- PANTALLA DE LOGIN ---
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _correoController = TextEditingController();
  final TextEditingController _contrasenaController = TextEditingController();
  bool _isLoading = false;

  Future<void> iniciarSesion() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:8000/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'correo': _correoController.text.trim(),
          'contrasena': _contrasenaController.text.trim(),
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String nombreUsuario = data['usuario']['nombre'];
        String rolUsuario = data['usuario']['rol'];
        String tokenJwt = data['access_token'];
        
        if (mounted) {
          if (rolUsuario == 'Profesional') {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => MenuProfesional(nombreUsuario: nombreUsuario, token: tokenJwt)),
            );
          } else {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => MenuCliente(nombreUsuario: nombreUsuario, token: tokenJwt)),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Correo o contraseña incorrectos'), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al conectar con el servidor.'), backgroundColor: Colors.orange));
      }
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.handyman, size: 64, color: Colors.blueAccent),
                    const SizedBox(height: 16),
                    const Text('ServiNow', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('Inicia sesión para continuar', style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 32),
                    TextField(controller: _correoController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo', prefixIcon: Icon(Icons.email), border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    TextField(controller: _contrasenaController, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock), border: OutlineInputBorder())),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        onPressed: _isLoading ? null : iniciarSesion,
                        child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : const Text('Entrar', style: TextStyle(fontSize: 18)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen())),
                      child: const Text('¿No tienes cuenta? Regístrate aquí'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- PANTALLA DE REGISTRO ---
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final TextEditingController _nombreController = TextEditingController();
  final TextEditingController _correoController = TextEditingController();
  final TextEditingController _telefonoController = TextEditingController();
  final TextEditingController _contrasenaController = TextEditingController();
  String _rolSeleccionado = 'Cliente';
  bool _isLoading = false;

  Future<void> registrarUsuario() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:8000/registro'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'nombre': _nombreController.text.trim(),
          'correo': _correoController.text.trim(),
          'telefono': _telefonoController.text.trim(),
          'contrasena': _contrasenaController.text.trim(),
          'rol': _rolSeleccionado,
        }),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('¡Registro exitoso!'), backgroundColor: Colors.green));
          Navigator.pop(context);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al registrar'), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al conectar con el servidor.'), backgroundColor: Colors.orange));
      }
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[150],
      appBar: AppBar(title: const Text('Registro'), backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: _nombreController, decoration: const InputDecoration(labelText: 'Nombre completo', border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    TextField(controller: _correoController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo', border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    TextField(controller: _telefonoController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Teléfono', border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    TextField(controller: _contrasenaController, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _rolSeleccionado,
                      decoration: const InputDecoration(labelText: 'Rol', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'Cliente', child: Text('Cliente')),
                        DropdownMenuItem(value: 'Profesional', child: Text('Profesional')),
                      ],
                      onChanged: (value) => setState(() => _rolSeleccionado = value!),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
                        onPressed: _isLoading ? null : registrarUsuario,
                        child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : const Text('Registrarse', style: TextStyle(fontSize: 18)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- MENÚ DEL CLIENTE ---
class MenuCliente extends StatelessWidget {
  final String nombreUsuario;
  final String token;

  const MenuCliente({super.key, required this.nombreUsuario, required this.token});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ServiNow - Cliente'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen())),
          ),
        ],
      ),
      body: _construirGrid(
        nombreUsuario,
        '¿Qué necesitas reparar hoy?',
        [
          _ItemMenu('Buscar Servicios', Icons.search, Colors.orange, () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => const MapaServiciosScreen()));
          }),
          _ItemMenu('Mis Solicitudes', Icons.assignment, Colors.blue, () {}),
          _ItemMenu('Favoritos', Icons.favorite, Colors.redAccent, () {}),
          _ItemMenu('Mi Perfil', Icons.person, Colors.purple, () {}),
        ],
      ),
    );
  }
}

// --- MENÚ DEL PROFESIONAL ---
class MenuProfesional extends StatelessWidget {
  final String nombreUsuario;
  final String token;

  const MenuProfesional({super.key, required this.nombreUsuario, required this.token});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ServiNow - Profesional'),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen()))),
        ],
      ),
      body: _construirGrid(
        nombreUsuario,
        'Panel de Trabajo',
        [
          _ItemMenu('Servicios Pendientes', Icons.build, Colors.teal, () {}),
          _ItemMenu('Mi Agenda', Icons.calendar_month, Colors.green, () {}),
          _ItemMenu('Ganancias', Icons.attach_money, Colors.amber, () {}),
          _ItemMenu('Mi Perfil Profesional', Icons.badge, Colors.indigo, () {}),
        ],
      ),
    );
  }
}

// --- PANTALLA DEL MAPA (CON BUSCADOR) ---
class MapaServiciosScreen extends StatefulWidget {
  const MapaServiciosScreen({super.key});

  @override
  State<MapaServiciosScreen> createState() => _MapaServiciosScreenState();
}

class _MapaServiciosScreenState extends State<MapaServiciosScreen> {
  LatLng? _posicionActual;
  bool _cargandoUbicacion = true;
  String _mensajeError = '';
  List<Marker> _marcadoresProfesionales = [];
  final TextEditingController _buscadorController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _obtenerUbicacion();
  }

  Future<void> _obtenerUbicacion() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() { _mensajeError = 'Activa el GPS.'; _cargandoUbicacion = false; });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() { _mensajeError = 'Permisos denegados.'; _cargandoUbicacion = false; });
        return;
      }
    }

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    
    setState(() {
      _posicionActual = LatLng(position.latitude, position.longitude);
      _cargandoUbicacion = false;
    });
  }

  Future<void> _buscarProfesionales(String busqueda) async {
    if (_posicionActual == null || busqueda.isEmpty) return;

    setState(() => _marcadoresProfesionales = []); 

    try {
      final lat = _posicionActual!.latitude;
      final lng = _posicionActual!.longitude;
      
      final response = await http.get(
        Uri.parse('http://127.0.0.1:8000/profesionales/cercanos?lat=$lat&lng=$lng&radio=15.0&busqueda=$busqueda'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final profesionales = data['profesionales'] as List;

        setState(() {
          _marcadoresProfesionales = profesionales.map((prof) {
            return Marker(
              point: LatLng(prof['latitud'], prof['longitud']),
              width: 100,
              height: 80,
              child: GestureDetector(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(prof['usuarios']['nombre']),
                      content: Text('Oficio: ${prof['oficio']}\nDistancia: ${prof['distancia_km']} km\nTeléfono: ${prof['usuarios']['telefono']}'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Próximamente: Crear solicitud de servicio'), backgroundColor: Colors.orange),
                            );
                          },
                          child: const Text('Solicitar'),
                        ),
                      ],
                    ),
                  );
                },
                child: Column(
                  children: [
                    const Icon(Icons.person_pin, color: Colors.green, size: 45),
                    Container(
                      padding: const EdgeInsets.all(2),
                      color: Colors.white.withOpacity(0.9),
                      child: Text(
                        prof['usuarios']['nombre'].toString().split(' ')[0],
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList();
        });
        
        if (profesionales.isEmpty && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se encontraron profesionales con ese oficio en tu zona.')),
          );
        }
      }
    } catch (e) {
      debugPrint("Error en búsqueda: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _buscadorController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Ej. plomero, cartero, electricista...',
            hintStyle: TextStyle(color: Colors.white70),
            border: InputBorder.none,
            icon: Icon(Icons.search, color: Colors.white),
          ),
          onSubmitted: (valor) => _buscarProfesionales(valor),
        ),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      body: _cargandoUbicacion
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : _posicionActual == null
              ? Center(child: Text(_mensajeError, style: const TextStyle(fontSize: 16, color: Colors.red)))
              : FlutterMap(
                  options: MapOptions(
                    initialCenter: _posicionActual!,
                    initialZoom: 14.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.servinow',
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _posicionActual!,
                          width: 60,
                          height: 60,
                          child: const Icon(Icons.my_location, color: Colors.blueAccent, size: 40),
                        ),
                        ..._marcadoresProfesionales,
                      ],
                    ),
                  ],
                ),
    );
  }
}

// --- WIDGETS REUTILIZABLES ---
class _ItemMenu {
  final String titulo;
  final IconData icono;
  final Color color;
  final VoidCallback onTap;
  _ItemMenu(this.titulo, this.icono, this.color, this.onTap);
}

Widget _construirGrid(String nombreUsuario, String subtitulo, List<_ItemMenu> items) {
  return Padding(
    padding: const EdgeInsets.all(24.0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('¡Hola, $nombreUsuario!', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(subtitulo, style: const TextStyle(color: Colors.grey, fontSize: 16)),
        const SizedBox(height: 24),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16,
            children: items.map((item) {
              return Card(
                elevation: 3, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: InkWell(
                  onTap: item.onTap, borderRadius: BorderRadius.circular(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icono, size: 48, color: item.color),
                      const SizedBox(height: 16),
                      Text(item.titulo, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    ),
  );
}