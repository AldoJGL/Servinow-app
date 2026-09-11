import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

void main() => runApp(const ServiNowApp());

// ---------- Estilo global ----------
const kPrimary = Color(0xFF0F0F1A); // Negro azulado
const kAccent = Color(0xFFFF7A1A);  // Naranja CTA
const kBg = Color(0xFFF6F7FB);
const kGray = Color(0xFF8A8A9E);

void _snack(BuildContext context, String msg, {Color color = kAccent}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(26)}) {
  return Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      boxShadow: [
        BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 10))
      ],
    ),
    child: child,
  );
}

Widget _button(String text, bool loading, VoidCallback? onPressed) {
  return SizedBox(
    width: double.infinity,
    height: 52,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: onPressed == null ? Colors.grey[300] : kAccent,
        foregroundColor: Colors.white,
        elevation: onPressed == null ? 0 : 4,
        shadowColor: kAccent.withOpacity(0.4),
      ),
      onPressed: onPressed,
      child: loading
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
          : Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    ),
  );
}

class ServiNowApp extends StatelessWidget {
  const ServiNowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ServiNow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        colorScheme: ColorScheme.fromSeed(seedColor: kAccent, primary: kPrimary, secondary: kAccent),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kBg,
          iconColor: kAccent,
          prefixIconColor: kAccent,
          contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
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
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => rolUsuario == 'Profesional'
                  ? MenuProfesional(nombreUsuario: nombreUsuario, token: tokenJwt)
                  : MenuCliente(nombreUsuario: nombreUsuario, token: tokenJwt),
            ),
          );
        }
      } else {
        if (mounted) _snack(context, 'Correo o contraseña incorrectos', color: Colors.red);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error al conectar con el servidor.', color: Colors.orange[800]!);
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPrimary,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(20)),
                  child: const Icon(Icons.handyman, size: 40, color: Colors.white),
                ),
                const SizedBox(height: 16),
                const Text('ServiNow', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
                Text('Servicios profesionales a un toque', style: TextStyle(color: Colors.white.withOpacity(0.6))),
                const SizedBox(height: 28),
                _card(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Align(alignment: Alignment.centerLeft, child: Text('Inicia sesión', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                      const SizedBox(height: 20),
                      TextField(controller: _correoController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo', prefixIcon: Icon(Icons.email_outlined))),
                      const SizedBox(height: 14),
                      TextField(controller: _contrasenaController, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock_outline))),
                      const SizedBox(height: 22),
                      _button('Entrar', _isLoading, _isLoading ? null : iniciarSesion),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen())),
                        child: const Text('¿No tienes cuenta? Regístrate aquí'),
                      ),
                    ],
                  ),
                ),
              ],
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
          _snack(context, '¡Registro exitoso!', color: Colors.green);
          Navigator.pop(context);
        }
      } else {
        if (mounted) _snack(context, 'Error al registrar', color: Colors.red);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error al conectar con el servidor.', color: Colors.orange[800]!);
    }
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Registro'), backgroundColor: kPrimary, foregroundColor: Colors.white),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: _card(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: _nombreController, decoration: const InputDecoration(labelText: 'Nombre completo', prefixIcon: Icon(Icons.person_outline))),
                const SizedBox(height: 14),
                TextField(controller: _correoController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo', prefixIcon: Icon(Icons.email_outlined))),
                const SizedBox(height: 14),
                TextField(controller: _telefonoController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Teléfono', prefixIcon: Icon(Icons.phone_outlined))),
                const SizedBox(height: 14),
                TextField(controller: _contrasenaController, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña', prefixIcon: Icon(Icons.lock_outline))),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: _rolSeleccionado,
                  decoration: const InputDecoration(labelText: 'Rol', prefixIcon: Icon(Icons.work_outline)),
                  items: const [
                    DropdownMenuItem(value: 'Cliente', child: Text('Cliente')),
                    DropdownMenuItem(value: 'Profesional', child: Text('Profesional')),
                  ],
                  onChanged: (value) => setState(() => _rolSeleccionado = value!),
                ),
                const SizedBox(height: 24),
                _button('Registrarse', _isLoading, _isLoading ? null : registrarUsuario),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- MENÚ DEL CLIENTE ---
class MenuCliente extends StatefulWidget {
  final String nombreUsuario;
  final String token;
  const MenuCliente({super.key, required this.nombreUsuario, required this.token});

  @override
  State<MenuCliente> createState() => _MenuClienteState();
}

class _MenuClienteState extends State<MenuCliente> {
  final TextEditingController _buscadorController = TextEditingController();

  final List<Map<String, dynamic>> _categoriasPopulares = [
    {
      'titulo': 'Mantenimiento de Clima',
      'query': 'clima',
      'icono': Icons.ac_unit,
      'color': const Color(0xFF2E3A59),
    },
    {
      'titulo': 'Carpintería',
      'query': 'carpintero',
      'icono': Icons.construction,
      'color': const Color(0xFF5D4037),
    },
    {
      'titulo': 'Cerrajería',
      'query': 'cerrajero',
      'icono': Icons.vpn_key,
      'color': const Color(0xFF37474F),
    },
    {
      'titulo': 'Plomería',
      'query': 'plomero',
      'icono': Icons.plumbing,
      'color': const Color(0xFF1E4C6E),
    },
    {
      'titulo': 'Electricidad',
      'query': 'electricista',
      'icono': Icons.bolt,
      'color': const Color(0xFF8C6D1F),
    },
    {
      'titulo': 'Pintura',
      'query': 'pintor',
      'icono': Icons.format_paint,
      'color': const Color(0xFF2E5B4B),
    },
  ];

  void _irAlMapaConBusqueda(String query) {
    if (query.trim().isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MapaServiciosScreen(busquedaInicial: query.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '¡Hola, ${widget.nombreUsuario}!',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: kPrimary),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        '¿Qué servicio necesitas hoy?',
                        style: TextStyle(color: kGray, fontSize: 14),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.logout, color: kPrimary),
                    onPressed: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (context) => const LoginScreen()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _buscadorController,
                  decoration: InputDecoration(
                    hintText: 'Ej. plomero, cerrajero, clima...',
                    hintStyle: const TextStyle(color: kGray, fontSize: 14),
                    prefixIcon: const Icon(Icons.search, color: kAccent, size: 26),
                    suffixIcon: _buscadorController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: kGray),
                            onPressed: () {
                              _buscadorController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onChanged: (val) => setState(() {}),
                  onSubmitted: (query) => _irAlMapaConBusqueda(query),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Los más buscados',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kPrimary),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.95,
                ),
                itemCount: _categoriasPopulares.length,
                itemBuilder: (context, index) {
                  final cat = _categoriasPopulares[index];
                  return Material(
                    color: cat['color'],
                    borderRadius: BorderRadius.circular(14),
                    elevation: 2,
                    shadowColor: (cat['color'] as Color).withOpacity(0.3),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _irAlMapaConBusqueda(cat['query']),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.18),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(cat['icono'], color: Colors.white, size: 22),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              cat['titulo'],
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
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
      body: _construirGrid(
        nombreUsuario,
        'Panel de Trabajo',
        [
          _ItemMenu('Servicios Pendientes', Icons.build, Colors.teal, () {}),
          _ItemMenu('Mi Agenda', Icons.calendar_month, Colors.green, () {}),
          _ItemMenu('Ganancias', Icons.attach_money, Colors.amber, () {}),
          _ItemMenu('Mi Perfil Profesional', Icons.badge, Colors.indigo, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => EditarPerfilProfesionalScreen(token: token)),
            );
          }),
        ],
      ),
    );
  }
}

// --- PANTALLA PARA EDITAR DESCRIPCIÓN E IMÁGENES (PROFESIONAL) ---
class EditarPerfilProfesionalScreen extends StatefulWidget {
  final String token;
  const EditarPerfilProfesionalScreen({super.key, required this.token});

  @override
  State<EditarPerfilProfesionalScreen> createState() => _EditarPerfilProfesionalScreenState();
}

class _EditarPerfilProfesionalScreenState extends State<EditarPerfilProfesionalScreen> {
  final TextEditingController _descripcionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  
  XFile? _foto1;
  XFile? _foto2;
  XFile? _foto3;
  bool _isLoading = false;

  Future<void> _seleccionarImagen(int numeroFoto) async {
    final XFile? imagen = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (imagen != null) {
      setState(() {
        if (numeroFoto == 1) _foto1 = imagen;
        if (numeroFoto == 2) _foto2 = imagen;
        if (numeroFoto == 3) _foto3 = imagen;
      });
    }
  }

  Future<void> _adjuntarArchivo(http.MultipartRequest request, String fieldName, XFile? archivo) async {
    if (archivo == null) return;
    
    final bytes = await archivo.readAsBytes();
    final extension = archivo.name.split('.').last.toLowerCase();
    final mimeType = (extension == 'png') ? 'png' : 'jpeg';

    request.files.add(
      http.MultipartFile.fromBytes(
        fieldName,
        bytes,
        filename: archivo.name,
        contentType: MediaType('image', mimeType),
      ),
    );
  }

  Future<void> _guardarPerfil() async {
    setState(() => _isLoading = true);
    try {
      var request = http.MultipartRequest(
        'PUT',
        Uri.parse('http://127.0.0.1:8000/profesionales/perfil'),
      );

      request.headers['Authorization'] = 'Bearer ${widget.token}';
      request.fields['descripcion'] = _descripcionController.text.trim();

      // Adjuntar archivos con MediaType explícito
      await _adjuntarArchivo(request, 'foto_1', _foto1);
      await _adjuntarArchivo(request, 'foto_2', _foto2);
      await _adjuntarArchivo(request, 'foto_3', _foto3);

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        if (mounted) {
          _snack(context, 'Perfil e imágenes guardados con éxito', color: Colors.green);
          Navigator.pop(context);
        }
      } else {
        print('=== ERROR SERVIDOR (${response.statusCode}) ===');
        print(response.body);

        if (mounted) {
          _snack(
            context, 
            'Error (${response.statusCode}): ${response.body}', 
            color: Colors.red,
          );
        }
      }
    } catch (e) {
      print('=== ERROR DE CONEXIÓN ===');
      print(e);
      if (mounted) {
        _snack(context, 'Error de conexión: $e', color: Colors.orange[800]!);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildSelectorImagen(String titulo, XFile? archivo, int numeroFoto) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(titulo, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _seleccionarImagen(numeroFoto),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 100,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: archivo == null
                ? const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo_outlined, color: kGray, size: 28),
                      SizedBox(height: 4),
                      Text('Toca para seleccionar foto', style: TextStyle(color: kGray, fontSize: 12)),
                    ],
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: kIsWeb
                        ? Image.network(archivo.path, fit: BoxFit.cover, width: double.infinity)
                        : Image.file(File(archivo.path), fit: BoxFit.cover, width: double.infinity),
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mi Perfil Profesional'), backgroundColor: kPrimary, foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Descripción de tus servicios', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _descripcionController,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Explica tu experiencia, especialidades, garantías o lo que te destaca...',
                ),
              ),
              const SizedBox(height: 20),
              const Text('Fotos de tus trabajos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('Selecciona fotos desde tu galería para mostrar tu trabajo.', style: TextStyle(fontSize: 12, color: kGray)),
              const SizedBox(height: 16),
              _buildSelectorImagen('Foto 1', _foto1, 1),
              const SizedBox(height: 12),
              _buildSelectorImagen('Foto 2', _foto2, 2),
              const SizedBox(height: 12),
              _buildSelectorImagen('Foto 3', _foto3, 3),
              const SizedBox(height: 24),
              _button('Guardar Perfil', _isLoading, _isLoading ? null : _guardarPerfil),
            ],
          ),
        ),
      ),
    );
  }
}

// --- PANTALLA DEL MAPA Y BUSCADOR ---
class MapaServiciosScreen extends StatefulWidget {
  final String? busquedaInicial;
  const MapaServiciosScreen({super.key, this.busquedaInicial});

  @override
  State<MapaServiciosScreen> createState() => _MapaServiciosScreenState();
}

class _MapaServiciosScreenState extends State<MapaServiciosScreen> {
  LatLng? _posicionActual;
  bool _cargandoUbicacion = true;
  String _mensajeError = '';
  List<Marker> _marcadoresProfesionales = [];
  List<dynamic> _listaProfesionales = [];
  final TextEditingController _buscadorController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.busquedaInicial != null) {
      _buscadorController.text = widget.busquedaInicial!;
    }
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

    if (widget.busquedaInicial != null && widget.busquedaInicial!.isNotEmpty) {
      _buscarProfesionales(widget.busquedaInicial!);
    }
  }

  void _abrirDetalleProfesional(dynamic prof) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PerfilProfesionalDetalleScreen(profesional: prof),
      ),
    );
  }

  Future<void> _buscarProfesionales(String busqueda) async {
    if (_posicionActual == null || busqueda.isEmpty) return;
    setState(() {
      _marcadoresProfesionales = [];
      _listaProfesionales = [];
    });

    try {
      final lat = _posicionActual!.latitude;
      final lng = _posicionActual!.longitude;
      final response = await http.get(
        Uri.parse('http://127.0.0.1:8000/profesionales/cercanos?lat=$lat&lng=$lng&radio=15.0&busqueda=$busqueda'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final profesionales = data['profesionales'] as List;
        profesionales.sort((a, b) => (a['distancia_km'] as num).compareTo(b['distancia_km'] as num));

        setState(() {
          _listaProfesionales = profesionales;
          _marcadoresProfesionales = profesionales.map((prof) {
            return Marker(
              point: LatLng(prof['latitud'], prof['longitud']),
              width: 100,
              height: 80,
              child: GestureDetector(
                onTap: () => _abrirDetalleProfesional(prof),
                child: Column(
                  children: [
                    const Icon(Icons.person_pin, color: Colors.green, size: 42),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                      child: Text(prof['usuarios']['nombre'].toString().split(' ')[0], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            );
          }).toList();
        });

        if (profesionales.isEmpty && mounted) {
          _snack(context, 'No se encontraron profesionales con ese oficio en tu zona.', color: kGray);
        }
      }
    } catch (e) {
      debugPrint("Error en búsqueda: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _cargandoUbicacion
              ? const Center(child: CircularProgressIndicator(color: kAccent))
              : _posicionActual == null
                  ? Center(child: Text(_mensajeError, style: const TextStyle(fontSize: 16, color: Colors.red)))
                  : FlutterMap(
                      options: MapOptions(initialCenter: _posicionActual!, initialZoom: 14.0),
                      children: [
                        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.servinow'),
                        MarkerLayer(markers: [
                          Marker(point: _posicionActual!, width: 60, height: 60, child: const Icon(Icons.my_location, color: kPrimary, size: 40)),
                          ..._marcadoresProfesionales,
                        ]),
                      ],
                    ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 4,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(context),
                      child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.arrow_back, color: kPrimary)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      elevation: 4,
                      child: TextField(
                        controller: _buscadorController,
                        decoration: const InputDecoration(
                          hintText: 'Ej. plomero, cerrajero, clima...',
                          hintStyle: TextStyle(color: kGray, fontSize: 14),
                          border: InputBorder.none,
                          filled: false,
                          prefixIcon: Icon(Icons.search, color: kAccent),
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                        ),
                        onSubmitted: (valor) => _buscarProfesionales(valor),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_listaProfesionales.isNotEmpty)
            DraggableScrollableSheet(
              initialChildSize: 0.5,
              minChildSize: 0.15,
              maxChildSize: 0.85,
              builder: (context, scrollController) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
                    boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20)],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10))),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                        child: Row(
                          children: [
                            Text('${_listaProfesionales.length} encontrados', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const Spacer(),
                            const Text('Más cercano primero', style: TextStyle(color: kGray, fontSize: 12)),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _listaProfesionales.length,
                          separatorBuilder: (context, index) => const Divider(height: 1, indent: 76),
                          itemBuilder: (context, index) {
                            final prof = _listaProfesionales[index];
                            return ListTile(
                              onTap: () => _abrirDetalleProfesional(prof),
                              leading: CircleAvatar(
                                backgroundColor: kAccent.withOpacity(0.12),
                                child: const Icon(Icons.person, color: kAccent),
                              ),
                              title: Text(prof['usuarios']['nombre'], style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text(prof['oficio']),
                              trailing: Text('${prof['distancia_km']} km', style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary)),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

// --- PANTALLA COMPLETA DE DETALLE DEL PROFESIONAL ---
class PerfilProfesionalDetalleScreen extends StatelessWidget {
  final dynamic profesional;
  const PerfilProfesionalDetalleScreen({super.key, required this.profesional});

  @override
  Widget build(BuildContext context) {
    final String nombre = profesional['usuarios']['nombre'] ?? 'Profesional';
    final String oficio = profesional['oficio'] ?? 'Sin especificar';
    final String telefono = profesional['usuarios']['telefono'] ?? 'N/A';
    final String descripcion = profesional['descripcion'] ?? '';
    final String distancia = '${profesional['distancia_km'] ?? '0.0'} km';

    List<String> fotos = [];
    if (profesional['foto_1'] != null && profesional['foto_1'].toString().trim().isNotEmpty) fotos.add(profesional['foto_1']);
    if (profesional['foto_2'] != null && profesional['foto_2'].toString().trim().isNotEmpty) fotos.add(profesional['foto_2']);
    if (profesional['foto_3'] != null && profesional['foto_3'].toString().trim().isNotEmpty) fotos.add(profesional['foto_3']);

    return Scaffold(
      appBar: AppBar(
        title: Text(nombre),
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 15)],
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: kAccent.withOpacity(0.15),
                          child: const Icon(Icons.person, size: 42, color: kAccent),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(nombre, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(oficio, style: const TextStyle(fontSize: 15, color: kAccent, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.location_on, size: 16, color: kGray),
                                  const SizedBox(width: 4),
                                  Text(distancia, style: const TextStyle(color: kGray, fontSize: 13)),
                                  const SizedBox(width: 16),
                                  const Icon(Icons.phone, size: 16, color: kGray),
                                  const SizedBox(width: 4),
                                  Text(telefono, style: const TextStyle(color: kGray, fontSize: 13)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('Descripción', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kPrimary)),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      descripcion.isNotEmpty ? descripcion : 'El profesional aún no ha añadido una descripción detallada.',
                      style: TextStyle(fontSize: 14, color: descripcion.isNotEmpty ? Colors.black87 : kGray, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('Trabajos realizados', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kPrimary)),
                  const SizedBox(height: 12),
                  fotos.isNotEmpty
                      ? SizedBox(
                          height: 160,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: fotos.length,
                            separatorBuilder: (context, index) => const SizedBox(width: 12),
                            itemBuilder: (context, index) {
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.network(
                                  fotos[index],
                                  width: 220,
                                  height: 160,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) => Container(
                                    width: 160,
                                    height: 160,
                                    color: Colors.grey[200],
                                    child: const Center(child: Icon(Icons.broken_image, color: kGray)),
                                  ),
                                ),
                              );
                            },
                          ),
                        )
                      : Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                          child: const Center(
                            child: Text('Sin fotografías de trabajos registradas.', style: TextStyle(color: kGray)),
                          ),
                        ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 15, offset: const Offset(0, -5))],
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
            ),
            child: SafeArea(
              child: _button('Solicitar servicio', false, () {
                _snack(context, 'Próximamente: Redirigir a pantalla de chat / mensajes');
              }),
            ),
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
  return Builder(builder: (context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 20, 24, 28),
          decoration: const BoxDecoration(
            color: kPrimary,
            borderRadius: BorderRadius.only(bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('¡Hola, $nombreUsuario!', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(subtitulo, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.white),
                onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen())),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              children: items.map((item) {
                return Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  elevation: 3,
                  shadowColor: Colors.black.withOpacity(0.1),
                  child: InkWell(
                    onTap: item.onTap,
                    borderRadius: BorderRadius.circular(18),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(color: item.color.withOpacity(0.12), shape: BoxShape.circle),
                          child: Icon(item.icono, size: 30, color: item.color),
                        ),
                        const SizedBox(height: 12),
                        Text(item.titulo, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  });
}