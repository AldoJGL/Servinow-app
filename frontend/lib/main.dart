import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
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

// Cambia aquí la URL del backend (Android emulador: http://10.0.2.2:8000, celular real: IP de tu PC)
const kBaseUrl = 'http://127.0.0.1:8000';

String _detalleError(String body) {
  try {
    final d = jsonDecode(body);
    if (d is Map && d['detail'] != null) return d['detail'].toString();
  } catch (_) {}
  return body;
}

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
        Uri.parse('$kBaseUrl/login'),
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
        final String idUsuario = data['usuario']['id_usuario']?.toString() ?? '';
        String tokenJwt = data['access_token'];

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => rolUsuario == 'Profesional'
                  ? MenuProfesional(nombreUsuario: nombreUsuario, token: tokenJwt, idUsuario: idUsuario)
                  : MenuCliente(nombreUsuario: nombreUsuario, token: tokenJwt, idUsuario: idUsuario),
            ),
          );
        }
      } else {
        if (mounted) _snack(context, 'Correo o contraseña incorrectos', color: Colors.red);
      }
    } catch (e) {
      debugPrint('Error en login: $e');
      if (mounted) _snack(context, 'Error en el login: $e', color: Colors.orange[800]!);
    }
    if (mounted) setState(() => _isLoading = false);
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
        Uri.parse('$kBaseUrl/registro'),
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
  final String idUsuario;
  const MenuCliente({super.key, required this.nombreUsuario, required this.token, required this.idUsuario});

  @override
  State<MenuCliente> createState() => _MenuClienteState();
}

class _MenuClienteState extends State<MenuCliente> {
  final TextEditingController _buscadorController = TextEditingController();
  int _mensajesSinLeer = 0;
  Timer? _notifTimer;

  final List<Map<String, dynamic>> _categoriasPopulares = [
    {'titulo': 'Mantenimiento de Clima', 'query': 'clima', 'icono': Icons.ac_unit, 'color': const Color(0xFF2E3A59)},
    {'titulo': 'Carpintería', 'query': 'carpintero', 'icono': Icons.construction, 'color': const Color(0xFF5D4037)},
    {'titulo': 'Cerrajería', 'query': 'cerrajero', 'icono': Icons.vpn_key, 'color': const Color(0xFF37474F)},
    {'titulo': 'Plomería', 'query': 'plomero', 'icono': Icons.plumbing, 'color': const Color(0xFF1E4C6E)},
    {'titulo': 'Electricidad', 'query': 'electricista', 'icono': Icons.bolt, 'color': const Color(0xFF8C6D1F)},
    {'titulo': 'Pintura', 'query': 'pintor', 'icono': Icons.format_paint, 'color': const Color(0xFF2E5B4B)},
  ];

  @override
  void initState() {
    super.initState();
    _consultarNotificaciones();
    _notifTimer = Timer.periodic(const Duration(seconds: 5), (_) => _consultarNotificaciones());
  }

  @override
  void dispose() {
    _notifTimer?.cancel();
    super.dispose();
  }

  Future<void> _consultarNotificaciones() async {
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/notificaciones/resumen'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            _mensajesSinLeer = data['mensajes_sin_leer'] ?? 0;
          });
        }
      }
    } catch (_) {}
  }

  void _irAlMapaConBusqueda(String query) {
    if (query.trim().isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MapaServiciosScreen(busquedaInicial: query.trim(), token: widget.token, idUsuario: widget.idUsuario),
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
                  Row(
                    children: [
                      Stack(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chat_bubble_outline, color: kAccent, size: 28),
                            tooltip: 'Mis Mensajes',
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ListaChatsScreen(token: widget.token, idUsuario: widget.idUsuario),
                                ),
                              ).then((_) => _consultarNotificaciones());
                            },
                          ),
                          if (_mensajesSinLeer > 0)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                                child: Text(
                                  '$_mensajesSinLeer',
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                ),
                              ),
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
class MenuProfesional extends StatefulWidget {
  final String nombreUsuario;
  final String token;
  final String idUsuario;
  const MenuProfesional({super.key, required this.nombreUsuario, required this.token, required this.idUsuario});

  @override
  State<MenuProfesional> createState() => _MenuProfesionalState();
}

class _MenuProfesionalState extends State<MenuProfesional> {
  int _solicitudesPendientesCount = 0;
  int _mensajesSinLeerCount = 0;
  Timer? _notifTimer;

  @override
  void initState() {
    super.initState();
    _obtenerConteoNotificaciones();
    _notifTimer = Timer.periodic(const Duration(seconds: 5), (_) => _obtenerConteoNotificaciones());
  }

  @override
  void dispose() {
    _notifTimer?.cancel();
    super.dispose();
  }

  Future<void> _obtenerConteoNotificaciones() async {
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/notificaciones/resumen'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            _solicitudesPendientesCount = data['solicitudes_pendientes'] ?? 0;
            _mensajesSinLeerCount = data['mensajes_sin_leer'] ?? 0;
          });
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _construirGrid(
        widget.nombreUsuario,
        'Panel de Trabajo',
        [
          _ItemMenu('Solicitudes Pendientes', Icons.build, Colors.teal, _solicitudesPendientesCount, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => SolicitudesPendientesScreen(token: widget.token, idUsuario: widget.idUsuario)),
            ).then((_) => _obtenerConteoNotificaciones());
          }),
          _ItemMenu('Mensajes / Chats', Icons.chat, Colors.orange, _mensajesSinLeerCount, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => ListaChatsScreen(token: widget.token, idUsuario: widget.idUsuario)),
            ).then((_) => _obtenerConteoNotificaciones());
          }),
          _ItemMenu('Ganancias', Icons.attach_money, Colors.amber, 0, () {}),
          _ItemMenu('Mi Perfil Profesional', Icons.badge, Colors.indigo, 0, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => EditarPerfilProfesionalScreen(token: widget.token)),
            );
          }),
        ],
      ),
    );
  }
}

// --- LISTA DE CHATS ACTIVOS ---
class ListaChatsScreen extends StatefulWidget {
  final String token;
  final String idUsuario;
  const ListaChatsScreen({super.key, required this.token, required this.idUsuario});

  @override
  State<ListaChatsScreen> createState() => _ListaChatsScreenState();
}

class _ListaChatsScreenState extends State<ListaChatsScreen> {
  bool _cargando = true;
  List<dynamic> _solicitudesAceptadas = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _cargarChats();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _cargarChats(silencioso: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _cargarChats({bool silencioso = false}) async {
    if (!silencioso) setState(() => _cargando = true);
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/solicitudes/activas'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _solicitudesAceptadas = data['solicitudes'] ?? []);
      } else if (!silencioso) {
        _snack(context, _detalleError(response.body), color: Colors.red);
      }
    } catch (e) {
      if (mounted && !silencioso) _snack(context, 'Error al cargar mensajes', color: Colors.red);
    }
    if (mounted) setState(() => _cargando = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mis Mensajes'), backgroundColor: kPrimary, foregroundColor: Colors.white),
      body: _cargando
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : _solicitudesAceptadas.isEmpty
              ? const Center(child: Text('No tienes chats activos por el momento.', style: TextStyle(color: kGray)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _solicitudesAceptadas.length,
                  itemBuilder: (context, index) {
                    final item = _solicitudesAceptadas[index];
                    final idSolicitud = item['id_solicitud'];
                    final contraparte = item['nombre_contacto'] ?? 'Usuario';
                    final bool tieneNuevos = (item['mensajes_sin_leer'] ?? 0) > 0;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: ListTile(
                        leading: Stack(
                          children: [
                            CircleAvatar(
                              backgroundColor: kAccent.withOpacity(0.15),
                              child: const Icon(Icons.person, color: kAccent),
                            ),
                            if (tieneNuevos)
                              Positioned(
                                right: 0,
                                top: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        title: Text(contraparte, style: TextStyle(fontWeight: tieneNuevos ? FontWeight.w800 : FontWeight.bold)),
                        subtitle: Text('Solicitud #$idSolicitud - ${item['descripcion_problema'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: tieneNuevos
                            ? Container(
                                padding: const EdgeInsets.all(6),
                                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                child: Text(
                                  '${item['mensajes_sin_leer']}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              )
                            : const Icon(Icons.chevron_right, color: kGray),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ChatScreen(
                                titulo: contraparte,
                                idSolicitud: idSolicitud,
                                token: widget.token,
                                idUsuarioActual: widget.idUsuario,
                              ),
                            ),
                          ).then((_) => _cargarChats());
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

// --- PANTALLA PARA VER Y ACEPTAR/RECHAZAR SOLICITUDES (PROFESIONAL) ---
class SolicitudesPendientesScreen extends StatefulWidget {
  final String token;
  final String idUsuario;
  const SolicitudesPendientesScreen({super.key, required this.token, required this.idUsuario});

  @override
  State<SolicitudesPendientesScreen> createState() => _SolicitudesPendientesScreenState();
}

class _SolicitudesPendientesScreenState extends State<SolicitudesPendientesScreen> {
  bool _cargando = true;
  List<dynamic> _solicitudes = [];

  @override
  void initState() {
    super.initState();
    _cargarSolicitudes();
  }

  Future<void> _cargarSolicitudes() async {
    setState(() => _cargando = true);
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/solicitudes/pendientes'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _solicitudes = data['solicitudes'] ?? []);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error al cargar solicitudes', color: Colors.red);
    }
    setState(() => _cargando = false);
  }

  Future<void> _responderSolicitud(int idSolicitud, String estado) async {
    try {
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$idSolicitud/estado'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'estado': estado}),
      );

      if (response.statusCode == 200) {
        _snack(
          context, 
          estado == 'aceptado' ? '¡Solicitud aceptada! Abriendo chat...' : 'Solicitud rechazada', 
          color: estado == 'aceptado' ? Colors.green : Colors.red
        );

        if (estado == 'aceptado' && mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                idSolicitud: idSolicitud,
                token: widget.token,
                idUsuarioActual: widget.idUsuario,
              ),
            ),
          );
        }

        _cargarSolicitudes();
      } else if (mounted) {
        _snack(context, _detalleError(response.body), color: Colors.red);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error al responder la solicitud', color: Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Solicitudes Pendientes'), backgroundColor: kPrimary, foregroundColor: Colors.white),
      body: _cargando
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : _solicitudes.isEmpty
              ? const Center(child: Text('No tienes solicitudes pendientes.', style: TextStyle(color: kGray)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _solicitudes.length,
                  itemBuilder: (context, index) {
                    final item = _solicitudes[index];
                    final clienteNombre = item['usuarios'] != null ? item['usuarios']['nombre'] : 'Cliente';
                    final clienteTel = item['usuarios'] != null ? item['usuarios']['telefono'] : 'N/A';
                    final direccion = item['direccion_texto'] ?? 'Dirección sin especificar';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: kAccent.withOpacity(0.12),
                                  child: const Icon(Icons.person, color: kAccent),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(clienteNombre, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                    Text('Tel: $clienteTel', style: const TextStyle(color: kGray, fontSize: 12)),
                                  ],
                                ),
                              ],
                            ),
                            const Divider(height: 24),
                            const Text('Descripción del problema:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: kPrimary)),
                            const SizedBox(height: 4),
                            Text(item['descripcion_problema'] ?? '', style: const TextStyle(fontSize: 14)),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.location_on, size: 18, color: kAccent),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    direccion, 
                                    style: const TextStyle(fontSize: 13, color: Colors.black87, fontWeight: FontWeight.w500)
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red,
                                      side: const BorderSide(color: Colors.red),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    onPressed: () => _responderSolicitud(item['id_solicitud'], 'rechazado'),
                                    child: const Text('Rechazar'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    onPressed: () => _responderSolicitud(item['id_solicitud'], 'aceptado'),
                                    child: const Text('Aceptar'),
                                  ),
                                ),
                              ],
                            )
                          ],
                        ),
                      ),
                    );
                  },
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
  // Debe coincidir con OFICIOS_VALIDOS del backend (y con las palabras del buscador de clientes)
  static const List<String> _oficios = [
    'Plomero',
    'Electricista',
    'Carpintero',
    'Cerrajero',
    'Pintor',
    'Técnico de clima',
  ];
  static const LatLng _centroPorDefecto = LatLng(25.7969, -100.2958); // Gral. Escobedo, N.L.

  final TextEditingController _descripcionController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  final MapController _mapController = MapController();

  XFile? _foto1;
  XFile? _foto2;
  XFile? _foto3;
  String? _oficio;
  LatLng? _ubicacion;
  String _direccionTexto = '';
  bool _isLoading = false;
  bool _cargandoPerfil = true;
  bool _obteniendoGps = false;

  @override
  void initState() {
    super.initState();
    _cargarPerfil();
  }

  @override
  void dispose() {
    _descripcionController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // Carga lo que el profesional ya tenía guardado (oficio, ubicación, descripción)
  Future<void> _cargarPerfil() async {
    try {
      final res = await http.get(
        Uri.parse('$kBaseUrl/profesionales/perfil'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200) {
        final p = jsonDecode(res.body)['profesional'];
        final oficioGuardado = p['oficio']?.toString();
        final lat = p['latitud'];
        final lng = p['longitud'];
        if (!mounted) return;
        setState(() {
          _descripcionController.text = (p['descripcion'] ?? '').toString();
          if (oficioGuardado != null && _oficios.contains(oficioGuardado)) {
            _oficio = oficioGuardado;
          }
          if (lat != null && lng != null) {
            _ubicacion = LatLng((lat as num).toDouble(), (lng as num).toDouble());
          }
        });
        if (_ubicacion != null) _actualizarDireccion(_ubicacion!);
      }
    } catch (e) {
      debugPrint('Error al cargar perfil: $e');
    } finally {
      if (mounted) setState(() => _cargandoPerfil = false);
    }
  }

  // Convierte coordenadas en una dirección legible (solo informativa)
  Future<void> _actualizarDireccion(LatLng punto) async {
    try {
      final url = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=${punto.latitude}&lon=${punto.longitude}');
      final res = await http.get(url, headers: {'User-Agent': 'ServinowApp/1.0 (contacto@servinow.com)'});
      if (res.statusCode == 200) {
        final address = jsonDecode(res.body)['address'] ?? {};
        final calle = address['road'] ?? address['pedestrian'] ?? '';
        final colonia = address['suburb'] ?? address['neighbourhood'] ?? '';
        final ciudad = address['city'] ?? address['town'] ?? address['village'] ?? '';
        final partes = [calle, colonia, ciudad].where((e) => e.toString().isNotEmpty).join(', ');
        // Si el usuario ya movió el pin a otro lado, ignoramos esta respuesta vieja
        if (mounted && _ubicacion == punto) setState(() => _direccionTexto = partes);
      }
    } catch (_) {}
  }

  void _fijarUbicacion(LatLng punto, {bool moverMapa = false}) {
    setState(() {
      _ubicacion = punto;
      _direccionTexto = '';
    });
    if (moverMapa) _mapController.move(punto, 16);
    _actualizarDireccion(punto);
  }

  Future<void> _usarMiUbicacion() async {
    setState(() => _obteniendoGps = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) _snack(context, 'Activa el GPS de tu dispositivo.', color: Colors.orange[800]!);
        return;
      }
      var permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied) {
        permiso = await Geolocator.requestPermission();
      }
      if (permiso == LocationPermission.denied || permiso == LocationPermission.deniedForever) {
        if (mounted) _snack(context, 'Permiso de ubicación denegado. También puedes tocar el mapa para marcar tu casa.', color: Colors.orange[800]!);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _fijarUbicacion(LatLng(pos.latitude, pos.longitude), moverMapa: true);
    } catch (e) {
      if (mounted) _snack(context, 'No se pudo obtener tu ubicación: $e', color: Colors.orange[800]!);
    } finally {
      if (mounted) setState(() => _obteniendoGps = false);
    }
  }

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
    if (_oficio == null) {
      _snack(context, 'Selecciona a qué te dedicas.', color: Colors.orange[800]!);
      return;
    }
    if (_ubicacion == null) {
      _snack(context, 'Marca tu ubicación para que los clientes cercanos puedan encontrarte.', color: Colors.orange[800]!);
      return;
    }

    setState(() => _isLoading = true);
    try {
      var request = http.MultipartRequest(
        'PUT',
        Uri.parse('$kBaseUrl/profesionales/perfil'),
      );

      request.headers['Authorization'] = 'Bearer ${widget.token}';
      request.fields['descripcion'] = _descripcionController.text.trim();
      request.fields['oficio'] = _oficio!;
      request.fields['latitud'] = _ubicacion!.latitude.toString();
      request.fields['longitud'] = _ubicacion!.longitude.toString();

      await _adjuntarArchivo(request, 'foto_1', _foto1);
      await _adjuntarArchivo(request, 'foto_2', _foto2);
      await _adjuntarArchivo(request, 'foto_3', _foto3);

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        if (mounted) {
          _snack(context, 'Perfil guardado con éxito', color: Colors.green);
          Navigator.pop(context);
        }
      } else {
        if (mounted) {
          _snack(context, 'Error (${response.statusCode}): ${_detalleError(response.body)}', color: Colors.red);
        }
      }
    } catch (e) {
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

  Widget _buildSelectorUbicacion() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _ubicacion ?? _centroPorDefecto,
                initialZoom: _ubicacion != null ? 16.0 : 12.0,
                onTap: (tapPosition, punto) => _fijarUbicacion(punto),
              ),
              children: [
                TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.servinow'),
                if (_ubicacion != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: _ubicacion!,
                      width: 50,
                      height: 50,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_on, color: kAccent, size: 44),
                    ),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _obteniendoGps ? null : _usarMiUbicacion,
            icon: _obteniendoGps
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location),
            label: const Text('Usar mi ubicación actual'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _ubicacion == null
              ? 'Toca el mapa para marcar dónde vives.'
              : (_direccionTexto.isEmpty ? 'Ubicación marcada.' : 'Ubicación marcada: $_direccionTexto'),
          style: TextStyle(fontSize: 12, color: _ubicacion == null ? Colors.red[700] : Colors.green[700], fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Los clientes verán tu pin en el mapa. Si prefieres no mostrar tu casa exacta, marca un punto cercano (por ejemplo, la esquina de tu colonia).',
          style: TextStyle(fontSize: 11, color: kGray),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mi Perfil Profesional'), backgroundColor: kPrimary, foregroundColor: Colors.white),
      body: _cargandoPerfil
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('¿A qué te dedicas?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: _oficio,
                      isExpanded: true,
                      hint: const Text('Selecciona tu especialidad'),
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.handyman_outlined)),
                      items: _oficios.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
                      onChanged: (v) => setState(() => _oficio = v),
                    ),
                    const SizedBox(height: 20),
                    const Text('Tu ubicación', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text('Sirve para que los clientes de tu zona te encuentren.', style: TextStyle(fontSize: 12, color: kGray)),
                    const SizedBox(height: 10),
                    _buildSelectorUbicacion(),
                    const SizedBox(height: 20),
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
  final String token;
  final String idUsuario;
  const MapaServiciosScreen({super.key, this.busquedaInicial, required this.token, required this.idUsuario});

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
        builder: (context) => PerfilProfesionalDetalleScreen(
          profesional: prof,
          posicionCliente: _posicionActual,
          token: widget.token,
          idUsuario: widget.idUsuario,
        ),
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
        Uri.parse('$kBaseUrl/profesionales/cercanos?lat=$lat&lng=$lng&radio=15.0&busqueda=$busqueda'),
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
class PerfilProfesionalDetalleScreen extends StatefulWidget {
  final dynamic profesional;
  final LatLng? posicionCliente;
  final String token;
  final String idUsuario;

  const PerfilProfesionalDetalleScreen({
    super.key, 
    required this.profesional, 
    this.posicionCliente,
    required this.token,
    required this.idUsuario,
  });

  @override
  State<PerfilProfesionalDetalleScreen> createState() => _PerfilProfesionalDetalleScreenState();
}

class _PerfilProfesionalDetalleScreenState extends State<PerfilProfesionalDetalleScreen> {
  final TextEditingController _problemaController = TextEditingController();
  bool _enviandoSolicitud = false;

  Future<String> _obtenerDireccionTexto(double lat, double lng) async {
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng');
      final res = await http.get(
        url, 
        headers: {'User-Agent': 'ServinowApp/1.0 (contacto@servinow.com)'}
      );
      
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final address = data['address'] ?? {};
        
        String calle = address['road'] ?? address['pedestrian'] ?? '';
        String numero = address['house_number'] ?? '';
        String colonia = address['suburb'] ?? address['neighbourhood'] ?? '';
        String ciudad = address['city'] ?? address['town'] ?? address['village'] ?? '';

        String dir = '$calle $numero, $colonia, $ciudad'.replaceAll(RegExp(r'^\s*,\s*'), '').trim();
        return dir.isNotEmpty ? dir : "Coordenadas: $lat, $lng";
      }
    } catch (e) {
      debugPrint("Error al obtener dirección HTTP: $e");
    }
    return "Ubicación GPS ($lat, $lng)";
  }

  void _mostrarModalSolicitud(BuildContext context) async {
    if (widget.posicionCliente == null) {
      _snack(context, 'No se tiene la ubicación actual del GPS.', color: Colors.orange[800]!);
      return;
    }

    _snack(context, 'Obteniendo tu dirección actual...');
    String direccionCalculada = await _obtenerDireccionTexto(
      widget.posicionCliente!.latitude, 
      widget.posicionCliente!.longitude
    );

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            left: 20,
            right: 20,
            top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Solicitar Servicio', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: kAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tu dirección asignada:\n$direccionCalculada',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('Describe tu problema:', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _problemaController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Ej. Necesito arreglar una fuga de agua en el baño principal...',
                ),
              ),
              const SizedBox(height: 20),
              StatefulBuilder(
                builder: (context, setModalState) {
                  return _button(
                    'Enviar Solicitud', 
                    _enviandoSolicitud, 
                    _enviandoSolicitud ? null : () async {
                      if (_problemaController.text.trim().isEmpty) {
                        _snack(context, 'Escribe la descripción de tu problema.', color: Colors.orange[800]!);
                        return;
                      }

                      setModalState(() => _enviandoSolicitud = true);
                      
                      try {
                        final response = await http.post(
                          Uri.parse('$kBaseUrl/solicitudes'),
                          headers: {
                            'Content-Type': 'application/json',
                            'Authorization': 'Bearer ${widget.token}',
                          },
                          body: jsonEncode({
                            'id_profesional': widget.profesional['id_profesional'],
                            'descripcion_problema': _problemaController.text.trim(),
                            'direccion_texto': direccionCalculada,
                            'latitud': widget.posicionCliente!.latitude,
                            'longitud': widget.posicionCliente!.longitude,
                          }),
                        );

                        if (response.statusCode == 200) {
                          if (mounted) {
                            Navigator.pop(context); // Cierra modal
                            _snack(context, '¡Solicitud enviada! Espera a que el profesional la acepte.', color: Colors.green);
                            _problemaController.clear();
                          }
                        } else {
                          if (mounted) _snack(context, 'Error al enviar la solicitud', color: Colors.red);
                        }
                      } catch (e) {
                        if (mounted) _snack(context, 'Error de conexión', color: Colors.red);
                      } finally {
                        setModalState(() => _enviandoSolicitud = false);
                      }
                    }
                  );
                }
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String nombre = widget.profesional['usuarios']['nombre'] ?? 'Profesional';
    final String oficio = widget.profesional['oficio'] ?? 'Sin especificar';
    final String telefono = widget.profesional['usuarios']['telefono'] ?? 'N/A';
    final String descripcion = widget.profesional['descripcion'] ?? '';
    final String distancia = '${widget.profesional['distancia_km'] ?? '0.0'} km';

    List<String> fotos = [];
    if (widget.profesional['foto_1'] != null && widget.profesional['foto_1'].toString().trim().isNotEmpty) fotos.add(widget.profesional['foto_1']);
    if (widget.profesional['foto_2'] != null && widget.profesional['foto_2'].toString().trim().isNotEmpty) fotos.add(widget.profesional['foto_2']);
    if (widget.profesional['foto_3'] != null && widget.profesional['foto_3'].toString().trim().isNotEmpty) fotos.add(widget.profesional['foto_3']);

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
              child: _button('Solicitar servicio', false, () => _mostrarModalSolicitud(context)),
            ),
          ),
        ],
      ),
    );
  }
}

// --- PANTALLA DE CHAT ---
class ChatScreen extends StatefulWidget {
  final int idSolicitud;
  final String token;
  final String idUsuarioActual;
  final String? titulo;

  const ChatScreen({
    super.key,
    required this.idSolicitud,
    required this.token,
    required this.idUsuarioActual,
    this.titulo,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _mensajeController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<dynamic> _mensajes = [];
  bool _cargando = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _cargarMensajes();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _cargarMensajes());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _mensajeController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollAlFinal() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  bool _esMio(dynamic msg) {
    final raw = msg['id_emisor'];
    return raw != null && raw.toString() == widget.idUsuarioActual.toString();
  }

  String _hora(dynamic iso) {
    final dt = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
    if (dt == null) return '';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _cargarMensajes() async {
    final url = Uri.parse('$kBaseUrl/solicitudes/${widget.idSolicitud}/mensajes');
    try {
      final res = await http.get(url, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final nuevos = (data['mensajes'] as List?) ?? [];
        final huboCambio = nuevos.length != _mensajes.length;
        setState(() {
          _mensajes = nuevos;
          _cargando = false;
        });
        if (huboCambio) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollAlFinal());
        }
      } else if (_cargando) {
        setState(() => _cargando = false);
        _snack(context, _detalleError(res.body), color: Colors.red);
      }
    } catch (e) {
      debugPrint("Error al consultar mensajes: $e");
    }
  }

  Future<void> _enviarMensaje() async {
    final texto = _mensajeController.text.trim();
    if (texto.isEmpty) return;

    _mensajeController.clear();
    final url = Uri.parse('$kBaseUrl/solicitudes/${widget.idSolicitud}/mensajes');

    try {
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'contenido': texto}),
      );

      if (res.statusCode == 200) {
        _cargarMensajes();
      } else {
        _mensajeController.text = texto; // no perder lo escrito
        if (mounted) _snack(context, _detalleError(res.body), color: Colors.red);
      }
    } catch (e) {
      _mensajeController.text = texto;
      if (mounted) _snack(context, 'Error de conexión al enviar el mensaje', color: Colors.red);
    }
  }

  Widget _burbuja(dynamic msg) {
    final bool esMio = _esMio(msg);
    final String hora = _hora(msg['fecha_envio']);

    return Align(
      alignment: esMio ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
        decoration: BoxDecoration(
          // Mío: naranja a la derecha. Del otro: gris azulado a la izquierda.
          color: esMio ? kAccent : const Color(0xFFE3E6F0),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16.0),
            topRight: const Radius.circular(16.0),
            bottomLeft: esMio ? const Radius.circular(16.0) : Radius.zero,
            bottomRight: esMio ? Radius.zero : const Radius.circular(16.0),
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: esMio ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              (msg['contenido'] ?? '').toString(),
              style: TextStyle(fontSize: 14.5, color: esMio ? Colors.white : kPrimary),
            ),
            if (hora.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                hora,
                style: TextStyle(fontSize: 10, color: esMio ? Colors.white70 : kGray),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titulo ?? 'Chat - Solicitud #${widget.idSolicitud}'),
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator(color: kAccent))
                : _mensajes.isEmpty
                    ? const Center(
                        child: Text('No hay mensajes aún. ¡Escribe el primero!', style: TextStyle(color: kGray)),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16.0),
                        itemCount: _mensajes.length,
                        itemBuilder: (context, index) => _burbuja(_mensajes[index]),
                      ),
          ),
          Container(
            padding: const EdgeInsets.all(12.0),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -3)),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _mensajeController,
                      decoration: const InputDecoration(
                        hintText: 'Escribe un mensaje...',
                        hintStyle: TextStyle(color: kGray, fontSize: 14),
                        border: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onSubmitted: (_) => _enviarMensaje(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: kAccent,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 20),
                      onPressed: _enviarMensaje,
                    ),
                  ),
                ],
              ),
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
  final int badgeCount;
  final VoidCallback onTap;
  _ItemMenu(this.titulo, this.icono, this.color, this.badgeCount, this.onTap);
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
                    child: Stack(
                      children: [
                        Center(
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
                        if (item.badgeCount > 0)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                              child: Text(
                                '${item.badgeCount}',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
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