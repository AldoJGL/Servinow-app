import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// Dirección del servidor. Se cambia al compilar: flutter build apk --release --dart-define=API_URL=https://tu-servidor.onrender.com
const kBaseUrl = String.fromEnvironment('API_URL', defaultValue: 'http://192.168.1.111:8000');

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

// ---------- Dirección legible y mapa pequeño (solicitudes de servicio) ----------
// Devuelve algo como "Av. Juárez 123, Col. Centro, Guadalupe". Si no se puede obtener, devuelve null.
Future<String?> obtenerDireccionLegible(double lat, double lng) async {
  try {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&zoom=18&accept-language=es&lat=$lat&lon=$lng');
    final res = await http
        .get(url, headers: {'User-Agent': 'ServinowApp/1.0 (contacto@servinow.com)'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body);
    final address = (data['address'] as Map?) ?? {};

    String elegir(List<String> claves) {
      for (final c in claves) {
        final v = address[c]?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    final calle = elegir(['road', 'pedestrian', 'footway', 'path', 'street']);
    final numero = elegir(['house_number']);
    final colonia = elegir(['suburb', 'neighbourhood', 'quarter', 'residential', 'city_district', 'hamlet']);
    final ciudad = elegir(['city', 'town', 'village', 'municipality', 'county']);

    final linea = [calle, numero].where((e) => e.isNotEmpty).join(' ');
    final partes = [linea, colonia, ciudad].where((e) => e.isNotEmpty).toList();
    if (partes.length >= 2) return partes.join(', ');

    // Si Nominatim devolvió pocos datos, usamos su nombre completo (recortado)
    final nombreCompleto = (data['display_name'] ?? '').toString();
    final trozos = nombreCompleto.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (trozos.length >= 2) return trozos.take(4).join(', ');

    return partes.isNotEmpty ? partes.join(', ') : null;
  } catch (e) {
    debugPrint('Error al obtener dirección: $e');
    return null;
  }
}

// Rectángulo con el mapa y el pin de una ubicación (no se puede mover, es solo para ver)
class MapaUbicacionMini extends StatelessWidget {
  final LatLng punto;
  final double alto;
  const MapaUbicacionMini({super.key, required this.punto, this.alto = 170});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: alto,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: IgnorePointer(
          child: FlutterMap(
            options: MapOptions(initialCenter: punto, initialZoom: 16.0),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.servinow'),
              MarkerLayer(markers: [
                Marker(
                  point: punto,
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
    );
  }
}

// Muestra la dirección de una solicitud. Si la que se guardó está incompleta (por ejemplo solo "Guadalupe"),
// la vuelve a calcular con las coordenadas.
class DireccionSolicitud extends StatefulWidget {
  final String textoGuardado;
  final double? lat;
  final double? lng;
  final TextStyle? style;
  const DireccionSolicitud({super.key, required this.textoGuardado, this.lat, this.lng, this.style});

  @override
  State<DireccionSolicitud> createState() => _DireccionSolicitudState();
}

class _DireccionSolicitudState extends State<DireccionSolicitud> {
  static final Map<String, String> _cache = {};
  String _texto = '';

  @override
  void initState() {
    super.initState();
    final segmentos = widget.textoGuardado.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final bool esPobre = segmentos.length < 2 ||
        widget.textoGuardado.startsWith('Ubicación GPS') ||
        widget.textoGuardado.startsWith('Coordenadas');
    _texto = segmentos.isEmpty ? 'Dirección sin especificar' : segmentos.join(', ');

    if (esPobre && widget.lat != null && widget.lng != null) {
      final clave = '${widget.lat!.toStringAsFixed(5)},${widget.lng!.toStringAsFixed(5)}';
      final enCache = _cache[clave];
      if (enCache != null) {
        _texto = enCache;
      } else {
        obtenerDireccionLegible(widget.lat!, widget.lng!).then((d) {
          if (d != null) {
            _cache[clave] = d;
            if (mounted) setState(() => _texto = d);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(_texto, style: widget.style);
  }
}

// ---------- Cotizaciones: utilidades compartidas ----------
String _dinero(dynamic valor) {
  final n = double.tryParse(valor?.toString() ?? '') ?? 0;
  return '\$${n.toStringAsFixed(2)} MXN';
}

// Caja de aviso con ícono y color (estado de una solicitud, mensajes informativos)
Widget _cajaInfo(IconData icono, Color color, String texto) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withOpacity(0.10),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: color.withOpacity(0.30)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icono, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(texto, style: const TextStyle(fontSize: 13, height: 1.4, color: kTextoOscuro))),
      ],
    ),
  );
}

// Etiqueta pequeña con el estado de una solicitud
Widget _chipEstado(String texto, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
    child: Text(texto, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
  );
}

// Colores de estado del nuevo diseño
const kEstadoAzul = Color(0xFF3B7A91);
const kEstadoVerde = Color(0xFF3E7A55);
const kEstadoRojo = Color(0xFFB4483C);

// Encabezado de pantallas internas: botón atrás + etiqueta + título grande (estilo Figma)
Widget _encabezadoPantalla(BuildContext context, String etiqueta, String titulo, String subtitulo) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFEAE6DD)),
            ),
            child: const Icon(Icons.arrow_back, color: kTextoOscuro, size: 20),
          ),
        ),
        const SizedBox(height: 22),
        Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
        const SizedBox(height: 10),
        Text(titulo, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1)),
        const SizedBox(height: 10),
        Text(subtitulo, style: const TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4)),
      ],
    ),
  );
}

// Estado vacío: icono en círculo pastel + texto
Widget _estadoVacio(IconData icono, String texto) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: Color(0xFFDCEBE0), shape: BoxShape.circle),
            child: Icon(icono, color: kVerde, size: 30),
          ),
          const SizedBox(height: 16),
          Text(texto, textAlign: TextAlign.center, style: const TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4)),
        ],
      ),
    ),
  );
}

// Tarjeta blanca de lista (bordes suaves, estilo Figma)
BoxDecoration _decoTarjeta() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFEAE6DD)),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
    );

// ---------- Calificaciones y reseñas (nuevo diseño) ----------
const kEstrella = Color(0xFFE0A526);

// Estrellas de solo lectura (admite medias estrellas, por ejemplo 4.5)
Widget _estrellas(num valor, {double size = 16}) {
  final double v = valor.toDouble();
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(5, (i) {
      IconData icono;
      if (v >= i + 1) {
        icono = Icons.star_rounded;
      } else if (v >= i + 0.5) {
        icono = Icons.star_half_rounded;
      } else {
        icono = Icons.star_outline_rounded;
      }
      return Icon(icono, size: size, color: kEstrella);
    }),
  );
}

String _textoCalificacion(int n) {
  switch (n) {
    case 1:
      return 'Muy malo';
    case 2:
      return 'Podría mejorar';
    case 3:
      return 'Estuvo bien';
    case 4:
      return 'Muy bueno';
    case 5:
      return 'Excelente';
    default:
      return 'Toca una estrella para calificar';
  }
}

// "12 oct 2026"
String _fechaCorta(dynamic iso) {
  final dt = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
  if (dt == null) return '';
  const meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  return '${dt.day} ${meses[dt.month - 1]} ${dt.year}';
}

// Foto a pantalla completa con zoom
void _mostrarFotoGrande(BuildContext context, String url) {
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: InkWell(
              onTap: () => Navigator.pop(ctx),
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 20, color: kTextoOscuro),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// Miniatura de una foto de reseña (toca para ampliar)
Widget _miniaturaFoto(BuildContext context, String url, {double lado = 84}) {
  return GestureDetector(
    onTap: () => _mostrarFotoGrande(context, url),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: lado,
        height: lado,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFFEFEBE3),
            child: const Icon(Icons.broken_image_outlined, color: kTextoSuave),
          ),
        ),
      ),
    ),
  );
}

// Bloque con la calificación que dejó el cliente (estrellas, comentario y foto)
Widget _bloqueResena(BuildContext context, dynamic resena, {String titulo = 'CALIFICACIÓN DEL CLIENTE'}) {
  if (resena == null) return const SizedBox.shrink();
  final int cal = int.tryParse((resena['calificacion'] ?? 0).toString()) ?? 0;
  final String comentario = (resena['comentario'] ?? '').toString().trim();
  final String foto = (resena['foto_url'] ?? '').toString().trim();

  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: kCrema,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFEAE6DD)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(titulo, style: const TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
        const SizedBox(height: 8),
        Row(
          children: [
            _estrellas(cal, size: 22),
            const SizedBox(width: 10),
            Text(_textoCalificacion(cal), style: const TextStyle(fontSize: 13, color: kTextoSuave, fontWeight: FontWeight.w600)),
          ],
        ),
        if (comentario.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(comentario, style: const TextStyle(fontSize: 14, height: 1.4, color: kTextoOscuro)),
        ],
        if (foto.isNotEmpty) ...[
          const SizedBox(height: 12),
          _miniaturaFoto(context, foto, lado: 96),
        ],
      ],
    ),
  );
}

// ---------- Ventana para pedir un texto (nota al terminar, motivo de "aún no está terminado") ----------
Future<String?> _pedirTexto(
  BuildContext context, {
  required String etiqueta,
  required String titulo,
  required String subtitulo,
  required String campo,
  required String hint,
  required String boton,
  bool obligatorio = false,
  IconData icono = Icons.edit_note,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DialogoTexto(
      etiqueta: etiqueta,
      titulo: titulo,
      subtitulo: subtitulo,
      campo: campo,
      hint: hint,
      boton: boton,
      obligatorio: obligatorio,
      icono: icono,
    ),
  );
}

class _DialogoTexto extends StatefulWidget {
  final String etiqueta, titulo, subtitulo, campo, hint, boton;
  final bool obligatorio;
  final IconData icono;
  const _DialogoTexto({
    required this.etiqueta,
    required this.titulo,
    required this.subtitulo,
    required this.campo,
    required this.hint,
    required this.boton,
    required this.obligatorio,
    required this.icono,
  });

  @override
  State<_DialogoTexto> createState() => _DialogoTextoState();
}

class _DialogoTextoState extends State<_DialogoTexto> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _enviar() {
    final texto = _controller.text.trim();
    if (widget.obligatorio && texto.length < 3) {
      setState(() => _error = 'Cuéntanos un poco más para continuar.');
      return;
    }
    Navigator.pop(context, texto);
  }

  @override
  Widget build(BuildContext context) {
    final borde = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: _error != null ? kCoral : const Color(0xFFE3DFD6)),
    );

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                  child: Icon(widget.icono, color: kVerde, size: 26),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: kCrema, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.close, color: kTextoOscuro, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(widget.etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            Text(widget.titulo, style: const TextStyle(color: kTextoOscuro, fontSize: 28, fontWeight: FontWeight.w600, height: 1.15)),
            const SizedBox(height: 10),
            Text(widget.subtitulo, style: const TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4)),
            const SizedBox(height: 22),
            Text(widget.campo, style: const TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              minLines: 4,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(16),
                enabledBorder: borde,
                border: borde,
                focusedBorder: borde.copyWith(borderSide: BorderSide(color: _error != null ? kCoral : kVerde, width: 1.4)),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(_error!, style: const TextStyle(color: kCoral, fontSize: 12.5)),
              ),
            const SizedBox(height: 22),
            _botonCoral(widget.boton, false, _enviar),
          ],
        ),
      ),
    );
  }
}

// ---------- Tarjeta "Reseñas" de un profesional (la ven el cliente y el propio profesional) ----------
class SeccionResenas extends StatefulWidget {
  final String idProfesional;
  final String token;
  const SeccionResenas({super.key, required this.idProfesional, required this.token});

  @override
  State<SeccionResenas> createState() => _SeccionResenasState();
}

class _SeccionResenasState extends State<SeccionResenas> {
  bool _cargando = true;
  bool _error = false;
  bool _verTodas = false;
  double? _promedio;
  int _total = 0;
  List<dynamic> _resenas = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final res = await http.get(
        Uri.parse('$kBaseUrl/profesionales/${widget.idProfesional}/resenas'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _promedio = (data['resumen']?['promedio'] as num?)?.toDouble();
          _total = int.tryParse((data['resumen']?['total'] ?? 0).toString()) ?? 0;
          _resenas = data['resenas'] ?? [];
        });
      } else {
        _error = true;
      }
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _cargando = false);
  }

  Widget _itemResena(dynamic r, {required bool ultima}) {
    final String nombre = (r['nombre_cliente'] ?? 'Cliente').toString();
    final String comentario = (r['comentario'] ?? '').toString().trim();
    final String foto = (r['foto_url'] ?? '').toString().trim();
    final int cal = int.tryParse((r['calificacion'] ?? 0).toString()) ?? 0;
    final String fecha = _fechaCorta(r['fecha_creacion']);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: ultima ? null : const Border(bottom: BorderSide(color: Color(0xFFEFEBE3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(10)),
                child: Text(nombre.isNotEmpty ? nombre[0].toUpperCase() : '?',
                    style: const TextStyle(color: kVerde, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombre, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                    if (fecha.isNotEmpty) Text(fecha, style: const TextStyle(fontSize: 11.5, color: kTextoSuave)),
                  ],
                ),
              ),
              _estrellas(cal, size: 15),
            ],
          ),
          if (comentario.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(comentario, style: const TextStyle(fontSize: 14, height: 1.4, color: kTextoOscuro)),
          ],
          if (foto.isNotEmpty) ...[
            const SizedBox(height: 10),
            _miniaturaFoto(context, foto),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error && !_cargando) return const SizedBox.shrink();

    final visibles = _verTodas ? _resenas : _resenas.take(3).toList();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFEAE6DD)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('OPINIONES DE CLIENTES',
              style: TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          const SizedBox(height: 10),
          const Text('Reseñas', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: kTextoOscuro)),
          const SizedBox(height: 16),
          if (_cargando)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: kCoral))),
            )
          else if (_total == 0 || _promedio == null)
            const Text(
              'Aún no hay reseñas. Aparecerán aquí cuando los clientes califiquen los trabajos terminados.',
              style: TextStyle(color: kTextoSuave, fontSize: 14, height: 1.4),
            )
          else ...[
            Row(
              children: [
                Text(_promedio!.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w700, color: kTextoOscuro, height: 1)),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _estrellas(_promedio!, size: 22),
                    const SizedBox(height: 4),
                    Text('$_total ${_total == 1 ? 'reseña' : 'reseñas'}', style: const TextStyle(fontSize: 13, color: kTextoSuave)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFEFEBE3)),
            for (int i = 0; i < visibles.length; i++) _itemResena(visibles[i], ultima: i == visibles.length - 1),
            if (_resenas.length > 3)
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _verTodas = !_verTodas),
                  child: Text(
                    _verTodas ? 'Ver menos' : 'Ver todas las reseñas',
                    style: const TextStyle(color: kCoral, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------- Pantalla del cliente: verificar que el trabajo terminó y calificarlo ----------
class CalificarTrabajoScreen extends StatefulWidget {
  final dynamic item; // solicitud (de /solicitudes/mias)
  final String token;
  const CalificarTrabajoScreen({super.key, required this.item, required this.token});

  @override
  State<CalificarTrabajoScreen> createState() => _CalificarTrabajoScreenState();
}

class _CalificarTrabajoScreenState extends State<CalificarTrabajoScreen> {
  final TextEditingController _comentarioController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  int _calificacion = 0;
  XFile? _foto;
  bool _enviando = false;

  @override
  void dispose() {
    _comentarioController.dispose();
    super.dispose();
  }

  Future<void> _elegirFoto(ImageSource fuente) async {
    try {
      final XFile? img = await _picker.pickImage(source: fuente, imageQuality: 80, maxWidth: 1600);
      if (img != null && mounted) setState(() => _foto = img);
    } catch (e) {
      if (mounted) _snack(context, 'No se pudo abrir la ${fuente == ImageSource.camera ? 'cámara' : 'galería'}.', color: kCoral);
    }
  }

  void _opcionesFoto() {
    if (kIsWeb) {
      _elegirFoto(ImageSource.gallery);
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: kCrema,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined, color: kVerde),
                title: const Text('Tomar una foto', style: TextStyle(fontWeight: FontWeight.w600, color: kTextoOscuro)),
                onTap: () {
                  Navigator.pop(ctx);
                  _elegirFoto(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined, color: kVerde),
                title: const Text('Elegir de la galería', style: TextStyle(fontWeight: FontWeight.w600, color: kTextoOscuro)),
                onTap: () {
                  Navigator.pop(ctx);
                  _elegirFoto(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enviar() async {
    if (_calificacion == 0) {
      _snack(context, 'Elige de 1 a 5 estrellas para calificar el trabajo.', color: kCoral);
      return;
    }
    setState(() => _enviando = true);
    try {
      final int id = (widget.item['id_solicitud'] as num).toInt();
      final request = http.MultipartRequest('POST', Uri.parse('$kBaseUrl/solicitudes/$id/resena'));
      request.headers['Authorization'] = 'Bearer ${widget.token}';
      request.fields['calificacion'] = '$_calificacion';
      request.fields['comentario'] = _comentarioController.text.trim();

      if (_foto != null) {
        final bytes = await _foto!.readAsBytes();
        final ext = _foto!.name.split('.').last.toLowerCase();
        final mime = ext == 'png' ? 'png' : (ext == 'webp' ? 'webp' : 'jpeg');
        request.files.add(http.MultipartFile.fromBytes(
          'foto',
          bytes,
          filename: _foto!.name,
          contentType: MediaType('image', mime),
        ));
      }

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      if (!mounted) return;
      if (response.statusCode == 200) {
        _snack(context, '¡Gracias! Confirmaste el trabajo y enviaste tu calificación.', color: kEstadoVerde);
        Navigator.pop(context, true);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión al enviar tu calificación', color: kEstadoRojo);
    }
    if (mounted) setState(() => _enviando = false);
  }

  Widget _tarjeta({required Widget child, String? etiqueta, required String titulo, String? subtitulo}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFEAE6DD)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (etiqueta != null) ...[
            Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            const SizedBox(height: 10),
          ],
          Text(titulo, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: kTextoOscuro)),
          if (subtitulo != null) ...[
            const SizedBox(height: 4),
            Text(subtitulo, style: const TextStyle(fontSize: 13, color: kTextoSuave, height: 1.35)),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final String nombre = (item['nombre_profesional'] ?? 'El profesional').toString();
    final String oficio = (item['oficio'] ?? '').toString();
    final String inicial = nombre.isNotEmpty ? nombre[0].toUpperCase() : '?';
    final String nota = (item['nota_cierre'] ?? '').toString().trim();
    final String terminado = _fechaPublicada(item['fecha_fin']);

    final borde = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE3DFD6)),
    );

    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _encabezadoPantalla(
              context,
              'TRABAJO TERMINADO',
              'Califica el servicio',
              '$nombre marcó el trabajo como terminado. Verifica que todo esté en orden y cuéntanos cómo fue.',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Resumen del trabajo
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: const Color(0xFFEAE6DD)),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(color: kVerde, borderRadius: BorderRadius.circular(16)),
                                child: Text(inicial, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(nombre, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                                    if (oficio.isNotEmpty)
                                      Text(oficio, style: const TextStyle(fontSize: 13, color: kCoral, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                              if (terminado.isNotEmpty)
                                Flexible(
                                  child: Text('Terminó $terminado',
                                      textAlign: TextAlign.right, style: const TextStyle(fontSize: 11.5, color: kTextoSuave)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(height: 1, color: Color(0xFFEFEBE3)),
                          const SizedBox(height: 14),
                          const Text('TU PROBLEMA', style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
                          const SizedBox(height: 6),
                          Text((item['descripcion_problema'] ?? '').toString(),
                              style: const TextStyle(fontSize: 14.5, height: 1.4, color: kTextoOscuro)),
                          if (nota.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            const Text('NOTA DEL PROFESIONAL',
                                style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
                            const SizedBox(height: 6),
                            Text(nota, style: const TextStyle(fontSize: 14.5, height: 1.4, color: kTextoOscuro)),
                          ],
                        ],
                      ),
                    ),
                    // Estrellas
                    _tarjeta(
                      titulo: '¿Cómo fue el servicio?',
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(5, (i) {
                              final activa = i < _calificacion;
                              return InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => setState(() => _calificacion = i + 1),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                                  child: Icon(
                                    activa ? Icons.star_rounded : Icons.star_outline_rounded,
                                    size: 46,
                                    color: activa ? kEstrella : const Color(0xFFD5D0C4),
                                  ),
                                ),
                              );
                            }),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _textoCalificacion(_calificacion),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: _calificacion == 0 ? FontWeight.w500 : FontWeight.w700,
                              color: _calificacion == 0 ? kTextoSuave : kTextoOscuro,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Comentario y foto
                    _tarjeta(
                      etiqueta: 'OPCIONAL',
                      titulo: 'Cuéntanos más',
                      subtitulo: 'Tu comentario y tu foto ayudan a otros clientes a elegir bien.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _comentarioController,
                            minLines: 4,
                            maxLines: 5,
                            maxLength: 500,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: 'Ej. Llegó puntual, resolvió la fuga y dejó todo limpio.',
                              hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
                              filled: true,
                              fillColor: Colors.white,
                              counterStyle: const TextStyle(color: kTextoSuave, fontSize: 11),
                              contentPadding: const EdgeInsets.all(16),
                              enabledBorder: borde,
                              border: borde,
                              focusedBorder: borde.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text('Foto del resultado', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          if (_foto == null)
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: _opcionesFoto,
                              child: Container(
                                width: double.infinity,
                                height: 110,
                                decoration: BoxDecoration(
                                  color: kCrema,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0xFFE3DFD6)),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.add_a_photo_outlined, color: kTextoSuave, size: 28),
                                    SizedBox(height: 6),
                                    Text('Añadir una foto', style: TextStyle(color: kTextoSuave, fontSize: 13)),
                                  ],
                                ),
                              ),
                            )
                          else
                            Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: SizedBox(
                                    width: double.infinity,
                                    height: 200,
                                    child: kIsWeb
                                        ? Image.network(_foto!.path, fit: BoxFit.cover)
                                        : Image.file(File(_foto!.path), fit: BoxFit.cover),
                                  ),
                                ),
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Row(
                                    children: [
                                      InkWell(
                                        onTap: _opcionesFoto,
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                          child: const Icon(Icons.edit_outlined, size: 18, color: kTextoOscuro),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      InkWell(
                                        onTap: () => setState(() => _foto = null),
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                          child: const Icon(Icons.delete_outline, size: 18, color: kEstadoRojo),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    _cajaInfo(Icons.verified_outlined, kEstadoVerde,
                        'Al enviar, confirmas que el trabajo quedó terminado. Si algo falta, regresa y elige "Aún no está terminado".'),
                    const SizedBox(height: 18),
                    _botonCoral('Confirmar y enviar', _enviando, _enviando ? null : _enviar),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Ayuda: botón "?" y pop-up de contacto ----------
const String kCorreoAyuda = 'servinowapp@gmail.com';

void _mostrarAyuda(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.help_outline, color: kVerde, size: 26),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: kCrema, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.close, color: kTextoOscuro, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text('AYUDA', style: TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            const Text('¿Necesitas ayuda?',
                style: TextStyle(color: kTextoOscuro, fontSize: 28, fontWeight: FontWeight.w600, height: 1.15)),
            const SizedBox(height: 10),
            const Text('Si necesitas ayuda, contáctanos:', style: TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4)),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCrema,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFEAE6DD)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mail_outline, color: kTextoSuave, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: SelectableText(kCorreoAyuda,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                  ),
                  IconButton(
                    tooltip: 'Copiar correo',
                    icon: const Icon(Icons.copy_outlined, size: 20, color: kVerde),
                    onPressed: () async {
                      await Clipboard.setData(const ClipboardData(text: kCorreoAyuda));
                      if (ctx.mounted) _snack(ctx, 'Correo copiado', color: kEstadoVerde);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// Botón cuadrado con el signo de interrogación
Widget _botonAyuda(BuildContext context) {
  return Tooltip(
    message: 'Ayuda',
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _mostrarAyuda(context),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEAE6DD)),
        ),
        child: const Icon(Icons.help_outline, color: kTextoOscuro, size: 22),
      ),
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

// ---------- Componentes del nuevo diseño (login y registro) ----------
Widget _campoNuevo({
  required String label,
  required TextEditingController controller,
  required String hint,
  required IconData icono,
  TextInputType? teclado,
  bool oculto = false,
}) {
  final borde = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: Color(0xFFE3DFD6)),
  );
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: teclado,
        obscureText: oculto,
        style: const TextStyle(color: kTextoOscuro, fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
          prefixIcon: Icon(icono, color: kTextoSuave, size: 22),
          prefixIconColor: kTextoSuave,
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          enabledBorder: borde,
          border: borde,
          focusedBorder: borde.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4)),
        ),
      ),
    ],
  );
}

Widget _botonCoral(String texto, bool cargando, VoidCallback? onPressed) {
  return SizedBox(
    width: double.infinity,
    height: 54,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: onPressed == null ? (cargando ? kCoral.withOpacity(0.75) : const Color(0xFFD9D5CC)) : kCoral,
        foregroundColor: Colors.white,
        elevation: onPressed == null ? 0 : 6,
        shadowColor: kCoral.withOpacity(0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: onPressed,
      child: cargando
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(texto, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                const Icon(Icons.arrow_forward, size: 20),
              ],
            ),
    ),
  );
}

Widget _logoServiNow() {
  return Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(color: kVerde, borderRadius: BorderRadius.circular(16)),
    child: const Icon(Icons.handyman, color: Colors.white, size: 28),
  );
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
      backgroundColor: kCrema,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _logoServiNow(),
                    const SizedBox(width: 14),
                    const Text('ServiNow', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                  ],
                ),
                const SizedBox(height: 36),
                const Text(
                  'BIENVENIDO',
                  style: TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
                ),
                const SizedBox(height: 12),
                const Text('Inicia sesión.', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1)),
                const SizedBox(height: 14),
                const Text(
                  'Servicios profesionales para tu hogar, a un toque de distancia.',
                  style: TextStyle(color: kTextoSuave, fontSize: 15.5, height: 1.4),
                ),
                const SizedBox(height: 28),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFEAE6DD)),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 18, offset: const Offset(0, 8))],
                  ),
                  child: Column(
                    children: [
                      _campoNuevo(
                        label: 'Correo',
                        controller: _correoController,
                        hint: 'tucorreo@ejemplo.com',
                        icono: Icons.email_outlined,
                        teclado: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 18),
                      _campoNuevo(
                        label: 'Contraseña',
                        controller: _contrasenaController,
                        hint: '••••••••',
                        icono: Icons.lock_outline,
                        oculto: true,
                      ),
                      const SizedBox(height: 24),
                      _botonCoral('Entrar', _isLoading, _isLoading ? null : iniciarSesion),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen())),
                    child: const Text.rich(
                      TextSpan(
                        text: '¿No tienes cuenta? ',
                        style: TextStyle(color: kTextoSuave, fontSize: 14.5),
                        children: [
                          TextSpan(text: 'Regístrate aquí', style: TextStyle(color: kCoral, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
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

  Widget _chipRol(String rol, IconData icono) {
    final activo = _rolSeleccionado == rol;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _rolSeleccionado = rol),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: activo ? kCoral.withOpacity(0.10) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: activo ? kCoral : const Color(0xFFE3DFD6), width: activo ? 1.4 : 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icono, size: 20, color: activo ? kCoral : kTextoSuave),
              const SizedBox(width: 8),
              Text(
                rol,
                style: TextStyle(
                  color: activo ? kCoral : kTextoOscuro,
                  fontWeight: activo ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEAE6DD)),
                  ),
                  child: const Icon(Icons.arrow_back, color: kTextoOscuro, size: 20),
                ),
              ),
              const SizedBox(height: 26),
              const Text(
                'NUEVA CUENTA',
                style: TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
              ),
              const SizedBox(height: 12),
              const Text('Crea tu cuenta.', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1)),
              const Text('Es muy sencillo.', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: kCoral, height: 1.15)),
              const SizedBox(height: 14),
              const Text(
                'Completa tus datos y empieza a pedir o a ofrecer servicios.',
                style: TextStyle(color: kTextoSuave, fontSize: 15.5, height: 1.4),
              ),
              const SizedBox(height: 28),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFFEAE6DD)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 18, offset: const Offset(0, 8))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _campoNuevo(label: 'Nombre completo', controller: _nombreController, hint: 'Ej. Lucía Ramírez', icono: Icons.person_outline),
                    const SizedBox(height: 18),
                    _campoNuevo(label: 'Correo', controller: _correoController, hint: 'tucorreo@ejemplo.com', icono: Icons.email_outlined, teclado: TextInputType.emailAddress),
                    const SizedBox(height: 18),
                    _campoNuevo(label: 'Teléfono', controller: _telefonoController, hint: 'Ej. 81 1234 5678', icono: Icons.phone_outlined, teclado: TextInputType.phone),
                    const SizedBox(height: 18),
                    _campoNuevo(label: 'Contraseña', controller: _contrasenaController, hint: '••••••••', icono: Icons.lock_outline, oculto: true),
                    const SizedBox(height: 22),
                    const Row(
                      children: [
                        Icon(Icons.work_outline, size: 18, color: kTextoOscuro),
                        SizedBox(width: 8),
                        Text('¿Cómo quieres usar ServiNow?', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _chipRol('Cliente', Icons.home_outlined),
                        const SizedBox(width: 10),
                        _chipRol('Profesional', Icons.handyman_outlined),
                      ],
                    ),
                    const SizedBox(height: 26),
                    _botonCoral('Registrarse', _isLoading, _isLoading ? null : registrarUsuario),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- MENÚ DEL CLIENTE ---
// Paleta del nuevo diseño (pantalla principal del cliente)
const kVerde = Color(0xFF1B4D45);     // Verde bosque (tarjeta de emergencia)
const kCoral = Color(0xFFEE7060);     // Coral (CTA y acentos)
const kCrema = Color(0xFFF7F4EE);     // Fondo cálido
const kTextoOscuro = Color(0xFF173B36);
const kTextoSuave = Color(0xFF6E7B77);

class MenuCliente extends StatefulWidget {
  final String nombreUsuario;
  final String token;
  final String idUsuario;
  const MenuCliente({super.key, required this.nombreUsuario, required this.token, required this.idUsuario});

  @override
  State<MenuCliente> createState() => _MenuClienteState();
}

class _MenuClienteState extends State<MenuCliente> {
  int _mensajesSinLeer = 0;
  int _cotizacionesPendientes = 0;
  bool _verTodos = false;
  Timer? _notifTimer;

  // Las 4 primeras se muestran siempre; el resto aparece con "Ver todos"
  final List<Map<String, dynamic>> _servicios = [
    {'titulo': 'Fontanería', 'sub': 'Fugas, atascos y averías', 'query': 'plomero', 'icono': Icons.water_drop_outlined, 'fondo': const Color(0xFFDDEBF0), 'tinta': const Color(0xFF3B7A91)},
    {'titulo': 'Electricidad', 'sub': 'Cortes, enchufes y cuadros', 'query': 'electricista', 'icono': Icons.bolt_outlined, 'fondo': const Color(0xFFF7EBC4), 'tinta': const Color(0xFF9A7413)},
    {'titulo': 'Reparaciones', 'sub': 'Persianas, puertas y más', 'query': 'carpintero', 'icono': Icons.build_outlined, 'fondo': const Color(0xFFDCEBE0), 'tinta': const Color(0xFF3E7A55)},
    {'titulo': 'Pintura', 'sub': 'Paredes, techos y acabados', 'query': 'pintor', 'icono': Icons.format_paint_outlined, 'fondo': const Color(0xFFF6DEDA), 'tinta': const Color(0xFFB4483C)},
    {'titulo': 'Cerrajería', 'sub': 'Llaves, chapas y cerraduras', 'query': 'cerrajero', 'icono': Icons.vpn_key_outlined, 'fondo': const Color(0xFFE4E2EE), 'tinta': const Color(0xFF5B5A8C)},
    {'titulo': 'Clima', 'sub': 'Aire acondicionado y mantenimiento', 'query': 'clima', 'icono': Icons.ac_unit, 'fondo': const Color(0xFFD9ECEA), 'tinta': const Color(0xFF2F7F78)},
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
            _cotizacionesPendientes = (data['cotizaciones_pendientes'] ?? 0) + (data['cierres_pendientes'] ?? 0) + (data['ajustes_pendientes'] ?? 0);
          });
        }
      }
    } catch (_) {}
  }

  void _irAlMapa([String? query, String? descripcion]) {
    final q = query?.trim();
    final d = descripcion?.trim();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MapaServiciosScreen(
          busquedaInicial: (q == null || q.isEmpty) ? null : q,
          descripcionInicial: (d == null || d.isEmpty) ? null : d,
          token: widget.token,
          idUsuario: widget.idUsuario,
        ),
      ),
    );
  }

  // Pop-up "Nueva solicitud": elige el servicio, describe el problema y busca profesionales
  Future<void> _abrirNuevaSolicitud() async {
    final resultado = await showDialog<Map<String, String>>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (ctx) => _DialogoNuevaSolicitud(servicios: _servicios),
    );
    if (resultado != null && mounted) {
      _irAlMapa(resultado['query'], resultado['descripcion']);
    }
  }

  void _irASolicitudes() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MisSolicitudesScreen(token: widget.token, idUsuario: widget.idUsuario)),
    ).then((_) => _consultarNotificaciones());
  }

  void _irAMensajes() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ListaChatsScreen(token: widget.token, idUsuario: widget.idUsuario)),
    ).then((_) => _consultarNotificaciones());
  }

  void _abrirPerfil() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCrema,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: kVerde,
                    child: Text(
                      widget.nombreUsuario.isNotEmpty ? widget.nombreUsuario[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.nombreUsuario,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: kTextoOscuro),
                    ),
                  ),
                  _botonAyuda(ctx),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kCoral,
                    side: const BorderSide(color: kCoral),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión', style: TextStyle(fontWeight: FontWeight.w700)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen()));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fechaHoy() {
    const dias = ['LUNES', 'MARTES', 'MIÉRCOLES', 'JUEVES', 'VIERNES', 'SÁBADO', 'DOMINGO'];
    const meses = ['ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO', 'JULIO', 'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE'];
    final h = DateTime.now();
    return '${dias[h.weekday - 1]}, ${h.day} DE ${meses[h.month - 1]}';
  }

  // ---------- Widgets ----------
  Widget _tarjetaEmergencia() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: kVerde,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: kVerde.withOpacity(0.25), blurRadius: 24, offset: const Offset(0, 12))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: kCoral.withOpacity(0.3), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: kCoral, shape: BoxShape.circle)),
              ),
              const SizedBox(width: 10),
              const Text(
                'AYUDA URGENTE',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.6),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            '¿Tienes una emergencia en casa?',
            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600, height: 1.15),
          ),
          const SizedBox(height: 14),
          Text(
            'Cuéntanos qué ocurre y encontraremos un profesional disponible cerca de ti.',
            style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 16, height: 1.4),
          ),
          const SizedBox(height: 22),
          Material(
            color: kCoral,
            borderRadius: BorderRadius.circular(16),
            elevation: 6,
            shadowColor: kCoral.withOpacity(0.5),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _abrirNuevaSolicitud,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 22, vertical: 15),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, color: Colors.white, size: 22),
                    SizedBox(width: 10),
                    Text('Solicitar ayuda ahora', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('Respuesta media', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
          const SizedBox(height: 2),
          const Text('12 min', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _tarjetaServicio(Map<String, dynamic> s) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEAE6DD)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _irAlMapa(s['query'] as String),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(color: s['fondo'] as Color, borderRadius: BorderRadius.circular(14)),
                  child: Icon(s['icono'] as IconData, color: s['tinta'] as Color, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s['titulo'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                      const SizedBox(height: 3),
                      Text(s['sub'] as String, style: const TextStyle(fontSize: 12.5, color: kTextoSuave)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: kTextoSuave),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _itemNav(IconData icono, String texto, {bool activo = false, bool punto = false, required VoidCallback onTap}) {
    final color = activo ? kCoral : kTextoSuave;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icono, color: color, size: 26),
                  if (punto)
                    Positioned(
                      top: -2,
                      right: -4,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: kCoral,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(texto, style: TextStyle(color: color, fontSize: 11.5, fontWeight: activo ? FontWeight.w700 : FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barraNavegacion() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: Color(0xFFEAE6DD))),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, -4))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _itemNav(Icons.home_outlined, 'Inicio', activo: true, onTap: () {}),
            _itemNav(Icons.handyman_outlined, 'Solicitudes', punto: _cotizacionesPendientes > 0, onTap: _irASolicitudes),
            _itemNav(Icons.chat_bubble_outline, 'Mensajes', punto: _mensajesSinLeer > 0, onTap: _irAMensajes),
            _itemNav(Icons.person_outline, 'Perfil', onTap: _abrirPerfil),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibles = _verTodos ? _servicios : _servicios.take(4).toList();

    return Scaffold(
      backgroundColor: kCrema,
      bottomNavigationBar: _barraNavegacion(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _fechaHoy(),
                style: const TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
              ),
              const SizedBox(height: 14),
              Text(
                'Hola, ${widget.nombreUsuario}.',
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1),
              ),
              const Text(
                '¿Todo bien en casa?',
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: kCoral, height: 1.15),
              ),
              const SizedBox(height: 14),
              const Text(
                'Estamos aquí para ayudarte con cualquier imprevisto, grande o pequeño.',
                style: TextStyle(color: kTextoSuave, fontSize: 15.5, height: 1.4),
              ),
              const SizedBox(height: 26),
              _tarjetaEmergencia(),
              const SizedBox(height: 32),
              const Text(
                '¿QUÉ NECESITAS?',
                style: TextStyle(color: kTextoSuave, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Expanded(
                    child: Text(
                      'Servicios para tu hogar',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: kTextoOscuro),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: kTextoOscuro, padding: const EdgeInsets.symmetric(horizontal: 4)),
                    onPressed: () => setState(() => _verTodos = !_verTodos),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_verTodos ? 'Ver menos' : 'Ver todos', style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        Icon(_verTodos ? Icons.arrow_upward : Icons.arrow_forward, size: 18),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final s in visibles) ...[
                _tarjetaServicio(s),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// --- POP-UP: NUEVA SOLICITUD (pantalla principal del cliente) ---
class _DialogoNuevaSolicitud extends StatefulWidget {
  final List<Map<String, dynamic>> servicios;
  const _DialogoNuevaSolicitud({required this.servicios});

  @override
  State<_DialogoNuevaSolicitud> createState() => _DialogoNuevaSolicitudState();
}

class _DialogoNuevaSolicitudState extends State<_DialogoNuevaSolicitud> {
  final TextEditingController _descripcionController = TextEditingController();
  String? _queryElegida;
  bool _mostrarError = false;

  @override
  void dispose() {
    _descripcionController.dispose();
    super.dispose();
  }

  void _buscar() {
    if (_queryElegida == null) {
      setState(() => _mostrarError = true);
      return;
    }
    Navigator.pop(context, {
      'query': _queryElegida!,
      'descripcion': _descripcionController.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bordeCampo = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE3DFD6)),
    );

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.build_outlined, color: kVerde, size: 26),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: kCrema, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.close, color: kTextoOscuro, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'NUEVA SOLICITUD',
              style: TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5),
            ),
            const SizedBox(height: 8),
            const Text(
              'Cuéntanos qué ocurre',
              style: TextStyle(color: kTextoOscuro, fontSize: 28, fontWeight: FontWeight.w600, height: 1.15),
            ),
            const SizedBox(height: 10),
            const Text(
              'Cuantos más detalles nos des, mejores serán las cotizaciones.',
              style: TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 22),
            const Text('Tipo de servicio', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _queryElegida,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, color: kTextoOscuro),
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(14),
              hint: const Text('Selecciona un servicio', style: TextStyle(color: kTextoOscuro, fontSize: 14.5, fontWeight: FontWeight.w600)),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                enabledBorder: bordeCampo,
                focusedBorder: bordeCampo.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4)),
                border: bordeCampo,
              ),
              items: [
                for (final s in widget.servicios)
                  DropdownMenuItem<String>(
                    value: s['query'] as String,
                    child: Text(s['titulo'] as String, style: const TextStyle(fontSize: 14.5, color: kTextoOscuro)),
                  ),
              ],
              onChanged: (v) => setState(() {
                _queryElegida = v;
                _mostrarError = false;
              }),
            ),
            if (_mostrarError)
              const Padding(
                padding: EdgeInsets.only(top: 6, left: 4),
                child: Text('Selecciona un servicio para continuar.', style: TextStyle(color: kCoral, fontSize: 12.5)),
              ),
            const SizedBox(height: 18),
            const Text('Describe el problema', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _descripcionController,
              minLines: 4,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Ej. Hay una fuga debajo del fregadero...',
                hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(16),
                enabledBorder: bordeCampo,
                focusedBorder: bordeCampo.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4)),
                border: bordeCampo,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kCoral,
                  foregroundColor: Colors.white,
                  elevation: 6,
                  shadowColor: kCoral.withOpacity(0.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _buscar,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Buscar profesionales', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    SizedBox(width: 10),
                    Icon(Icons.arrow_forward, size: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Barra inferior reutilizable (nuevo diseño) ---
Widget _itemNavInferior(IconData icono, String texto, {bool activo = false, bool punto = false, required VoidCallback onTap}) {
  final color = activo ? kCoral : kTextoSuave;
  return Expanded(
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icono, color: color, size: 26),
                if (punto)
                  Positioned(
                    top: -2,
                    right: -4,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: kCoral,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(texto, style: TextStyle(color: color, fontSize: 11.5, fontWeight: activo ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      ),
    ),
  );
}

Widget _barraInferior(List<Widget> items) {
  return Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: const Border(top: BorderSide(color: Color(0xFFEAE6DD))),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, -4))],
    ),
    child: SafeArea(top: false, child: Row(children: items)),
  );
}

// "Hace 5 min", "Hace 3 h", "Hace 2 d"
String _haceTiempo(dynamic iso) {
  final dt = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'Hace un momento';
  if (diff.inMinutes < 60) return 'Hace ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'Hace ${diff.inHours} h';
  return 'Hace ${diff.inDays} d';
}

// --- MENÚ DEL PROFESIONAL (pantalla principal: solicitudes recibidas) ---
class MenuProfesional extends StatefulWidget {
  final String nombreUsuario;
  final String token;
  final String idUsuario;
  const MenuProfesional({super.key, required this.nombreUsuario, required this.token, required this.idUsuario});

  @override
  State<MenuProfesional> createState() => _MenuProfesionalState();
}

class _MenuProfesionalState extends State<MenuProfesional> {
  int _tab = 0; // 0 = Nuevas, 1 = En curso, 2 = Completadas
  bool _cargando = true;
  List<dynamic> _solicitudes = []; // pendiente, aceptado, cotizado, cotizacion_rechazada
  List<dynamic> _trabajos = []; // confirmado, en_curso, por_verificar, completado
  int _mensajesSinLeerCount = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _cargarTodo();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _cargarTodo(silencioso: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _cargarTodo({bool silencioso = false}) async {
    if (!silencioso) setState(() => _cargando = true);
    final headers = {'Authorization': 'Bearer ${widget.token}'};
    try {
      final resultados = await Future.wait([
        http.get(Uri.parse('$kBaseUrl/solicitudes/pendientes'), headers: headers),
        http.get(Uri.parse('$kBaseUrl/solicitudes/trabajos'), headers: headers),
        http.get(Uri.parse('$kBaseUrl/notificaciones/resumen'), headers: headers),
      ]);
      if (!mounted) return;
      setState(() {
        if (resultados[0].statusCode == 200) {
          _solicitudes = jsonDecode(resultados[0].body)['solicitudes'] ?? [];
        }
        if (resultados[1].statusCode == 200) {
          _trabajos = jsonDecode(resultados[1].body)['solicitudes'] ?? [];
        }
        if (resultados[2].statusCode == 200) {
          _mensajesSinLeerCount = jsonDecode(resultados[2].body)['mensajes_sin_leer'] ?? 0;
        }
      });
    } catch (e) {
      if (mounted && !silencioso) _snack(context, 'Error al cargar solicitudes', color: kEstadoRojo);
    }
    if (mounted) setState(() => _cargando = false);
  }

  int get _nuevasCount => _solicitudes.where((e) => (e['estado'] ?? '') == 'pendiente').length;

  // Trabajos que el cliente ya confirmó y siguen abiertos (por iniciar, en curso o por verificar)
  List<dynamic> get _enCurso =>
      _trabajos.where((e) => const ['confirmado', 'en_curso', 'por_verificar', 'ajuste_pendiente'].contains(e['estado'])).toList();
  List<dynamic> get _completadas => _trabajos.where((e) => e['estado'] == 'completado').toList();
  int get _porIniciarCount => _trabajos.where((e) => e['estado'] == 'confirmado').length;

  void _abrirDetalle(dynamic item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DetalleSolicitudProfesionalScreen(item: item, token: widget.token, idUsuario: widget.idUsuario)),
    ).then((_) => _cargarTodo(silencioso: true));
  }

  void _irAMensajes() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ListaChatsScreen(token: widget.token, idUsuario: widget.idUsuario)),
    ).then((_) => _cargarTodo(silencioso: true));
  }

  void _abrirPerfil() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCrema,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: kVerde,
                    child: Text(
                      widget.nombreUsuario.isNotEmpty ? widget.nombreUsuario[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(widget.nombreUsuario, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                  ),
                  _botonAyuda(ctx),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kVerde,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.badge_outlined),
                  label: const Text('Mi perfil profesional', style: TextStyle(fontWeight: FontWeight.w700)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => EditarPerfilProfesionalScreen(token: widget.token, nombreUsuario: widget.nombreUsuario)),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kCoral,
                    side: const BorderSide(color: kCoral),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión', style: TextStyle(fontWeight: FontWeight.w700)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen()));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Widgets ----------
  Widget _chipFila(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(
        texto.toUpperCase(),
        style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.6),
      ),
    );
  }

  Widget _pestana(String texto, int indice, {int badge = 0}) {
    final activa = _tab == indice;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = indice),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: activa ? kCoral : Colors.transparent, width: 2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                texto,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: activa ? FontWeight.w800 : FontWeight.w600,
                  color: activa ? kTextoOscuro : kTextoSuave,
                ),
              ),
              if (badge > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: kCoral, borderRadius: BorderRadius.circular(10)),
                  child: Text('$badge', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _filaSolicitud(dynamic item, {required bool ultima}) {
    final String estado = (item['estado'] ?? 'pendiente').toString();
    final String cliente = item['usuarios'] != null ? (item['usuarios']['nombre'] ?? 'Cliente').toString() : 'Cliente';
    final String direccion = (item['direccion_texto'] ?? '').toString().trim();
    final String descripcion = (item['descripcion_problema'] ?? '').toString().trim();
    final String hace = _haceTiempo(item['fecha_creacion']);
    final bool esNueva = estado == 'pendiente';

    late final Color fondoTile;
    late final Color tintaTile;
    late final IconData iconoTile;
    late final String textoChip;
    late final Color colorChip;
    switch (estado) {
      case 'aceptado':
        fondoTile = const Color(0xFFF7EBC4);
        tintaTile = const Color(0xFF9A7413);
        iconoTile = Icons.edit_note;
        textoChip = 'Por cotizar';
        colorChip = kEstadoAzul;
        break;
      case 'cotizado':
        fondoTile = const Color(0xFFDCEBE0);
        tintaTile = kEstadoVerde;
        iconoTile = Icons.hourglass_top;
        textoChip = 'Esperando';
        colorChip = kEstadoVerde;
        break;
      case 'cotizacion_rechazada':
        fondoTile = const Color(0xFFF6DEDA);
        tintaTile = kEstadoRojo;
        iconoTile = Icons.cancel_outlined;
        textoChip = 'Rechazada';
        colorChip = kEstadoRojo;
        break;
      default:
        fondoTile = const Color(0xFFDDEBF0);
        tintaTile = kEstadoAzul;
        iconoTile = Icons.build_outlined;
        textoChip = 'Nueva';
        colorChip = kCoral;
    }

    return Container(
      decoration: BoxDecoration(
        color: esNueva ? const Color(0xFFEAF2EF) : Colors.white,
        border: ultima ? null : const Border(bottom: BorderSide(color: Color(0xFFEFEBE3))),
      ),
      child: InkWell(
        onTap: () => _abrirDetalle(item),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: fondoTile, borderRadius: BorderRadius.circular(14)),
                child: Icon(iconoTile, color: tintaTile, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            descripcion.isEmpty ? 'Solicitud #${item['id_solicitud']}' : descripcion,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kTextoOscuro),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _chipFila(textoChip, colorChip),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      direccion.isEmpty ? cliente : '$cliente · $direccion',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: kTextoSuave),
                    ),
                    if (hace.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(hace, style: TextStyle(fontSize: 12, color: kTextoSuave.withOpacity(0.8))),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filaTrabajo(dynamic item, {required bool ultima}) {
    final String estado = (item['estado'] ?? '').toString();
    final String cliente = item['usuarios'] != null ? (item['usuarios']['nombre'] ?? 'Cliente').toString() : 'Cliente';
    final String direccion = (item['direccion_texto'] ?? '').toString().trim();
    final String descripcion = (item['descripcion_problema'] ?? '').toString().trim();

    Color fondoTile;
    Color tintaTile;
    Color colorChip;
    IconData iconoTile;
    String textoChip;
    Widget detalle;

    switch (estado) {
      case 'confirmado':
        fondoTile = const Color(0xFFDDEBF0);
        tintaTile = kEstadoAzul;
        colorChip = kEstadoAzul;
        iconoTile = Icons.play_circle_outline;
        textoChip = 'Por iniciar';
        detalle = const Text('Toca para iniciar el trabajo',
            style: TextStyle(fontSize: 12, color: kCoral, fontWeight: FontWeight.w700));
        break;
      case 'en_curso':
        final hace = _haceTiempo(item['fecha_inicio']);
        fondoTile = const Color(0xFFDCEBE0);
        tintaTile = kEstadoVerde;
        colorChip = kEstadoVerde;
        iconoTile = Icons.construction;
        textoChip = 'En curso';
        detalle = Text(hace.isEmpty ? 'Trabajo en curso' : 'Inició ${hace.toLowerCase()}',
            style: const TextStyle(fontSize: 12, color: kTextoSuave));
        break;
      case 'ajuste_pendiente':
        fondoTile = const Color(0xFFF6DEDA);
        tintaTile = kCoral;
        colorChip = kCoral;
        iconoTile = Icons.request_quote_outlined;
        textoChip = 'Nuevo precio';
        detalle = const Text('Esperando la respuesta del cliente', style: TextStyle(fontSize: 12, color: kTextoSuave));
        break;
      case 'por_verificar':
        fondoTile = const Color(0xFFF7EBC4);
        tintaTile = const Color(0xFF9A7413);
        colorChip = kCoral;
        iconoTile = Icons.hourglass_top;
        textoChip = 'Por verificar';
        detalle = const Text('Esperando la verificación del cliente', style: TextStyle(fontSize: 12, color: kTextoSuave));
        break;
      default:
        final resena = item['resena'];
        final int cal = resena == null ? 0 : (int.tryParse((resena['calificacion'] ?? 0).toString()) ?? 0);
        fondoTile = const Color(0xFFDCEBE0);
        tintaTile = kEstadoVerde;
        colorChip = kEstadoVerde;
        iconoTile = Icons.check_circle_outline;
        textoChip = 'Completado';
        detalle = Row(
          children: [
            if (cal > 0) ...[
              _estrellas(cal, size: 14),
              const SizedBox(width: 8),
            ],
            Text(_fechaCorta(item['fecha_completado']), style: const TextStyle(fontSize: 12, color: kTextoSuave)),
          ],
        );
    }

    return Container(
      decoration: BoxDecoration(
        color: estado == 'confirmado' ? const Color(0xFFEAF2EF) : Colors.white,
        border: ultima ? null : const Border(bottom: BorderSide(color: Color(0xFFEFEBE3))),
      ),
      child: InkWell(
        onTap: () => _abrirDetalle(item),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: fondoTile, borderRadius: BorderRadius.circular(14)),
                child: Icon(iconoTile, color: tintaTile, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            descripcion.isEmpty ? 'Solicitud #${item['id_solicitud']}' : descripcion,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kTextoOscuro),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _chipFila(textoChip, colorChip),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      direccion.isEmpty ? cliente : '$cliente · $direccion',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: kTextoSuave),
                    ),
                    const SizedBox(height: 8),
                    detalle,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _contenidoLista() {
    if (_cargando) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator(color: kCoral)),
      );
    }
    final List<dynamic> lista = _tab == 0 ? _solicitudes : (_tab == 1 ? _enCurso : _completadas);
    if (lista.isEmpty) {
      final IconData icono = _tab == 0 ? Icons.handyman_outlined : (_tab == 1 ? Icons.construction : Icons.check_circle_outline);
      final String texto = _tab == 0
          ? 'No tienes solicitudes por atender.'
          : (_tab == 1
              ? 'Cuando un cliente acepte tu cotización, el trabajo aparecerá aquí para que lo inicies.'
              : 'Aquí verás los trabajos que el cliente ya verificó y calificó.');
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: _estadoVacio(icono, texto),
      );
    }
    return Column(
      children: [
        for (int i = 0; i < lista.length; i++)
          _tab == 0
              ? _filaSolicitud(lista[i], ultima: i == lista.length - 1)
              : _filaTrabajo(lista[i], ultima: i == lista.length - 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kCrema,
      bottomNavigationBar: _barraInferior([
        _itemNavInferior(Icons.handyman_outlined, 'Solicitudes', activo: true, onTap: () {}),
        _itemNavInferior(Icons.chat_bubble_outline, 'Mensajes', punto: _mensajesSinLeerCount > 0, onTap: _irAMensajes),
        _itemNavInferior(
          Icons.account_balance_wallet_outlined,
          'Ganancias',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => GananciasScreen(token: widget.token)),
          ),
        ),
        _itemNavInferior(Icons.person_outline, 'Perfil', onTap: _abrirPerfil),
      ]),
      body: SafeArea(
        child: RefreshIndicator(
          color: kCoral,
          onRefresh: () => _cargarTodo(silencioso: true),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TUS OPORTUNIDADES',
                  style: TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Solicitudes recibidas',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Revisa las peticiones de clientes y envía tus cotizaciones.',
                  style: TextStyle(color: kTextoSuave, fontSize: 15.5, height: 1.4),
                ),
                const SizedBox(height: 28),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: const Color(0xFFEAE6DD)),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(25),
                    child: Material(
                      color: Colors.white,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              _pestana('Nuevas', 0, badge: _nuevasCount),
                              _pestana('En curso', 1, badge: _porIniciarCount),
                              _pestana('Completadas', 2),
                            ],
                          ),
                          const Divider(height: 1, color: Color(0xFFEFEBE3)),
                          _contenidoLista(),
                        ],
                      ),
                    ),
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
      backgroundColor: kCrema,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _encabezadoPantalla(context, 'TUS CONVERSACIONES', 'Mensajes', 'Coordina los detalles del servicio con tu profesional.'),
            const SizedBox(height: 8),
            Expanded(
              child: _cargando
                  ? const Center(child: CircularProgressIndicator(color: kCoral))
                  : _solicitudesAceptadas.isEmpty
                      ? _estadoVacio(Icons.chat_bubble_outline, 'No tienes chats activos por el momento.')
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                          itemCount: _solicitudesAceptadas.length,
                          itemBuilder: (context, index) {
                            final item = _solicitudesAceptadas[index];
                            final idSolicitud = item['id_solicitud'];
                            final contraparte = (item['nombre_contacto'] ?? 'Usuario').toString();
                            final int sinLeer = int.tryParse((item['mensajes_sin_leer'] ?? 0).toString()) ?? 0;
                            final bool tieneNuevos = sinLeer > 0;
                            final inicial = contraparte.isNotEmpty ? contraparte[0].toUpperCase() : '?';

                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: tieneNuevos ? kCoral.withOpacity(0.5) : const Color(0xFFEAE6DD)),
                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
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
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 54,
                                          height: 54,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                                          child: Text(inicial, style: const TextStyle(color: kVerde, fontSize: 22, fontWeight: FontWeight.w700)),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                contraparte,
                                                style: TextStyle(fontSize: 16, fontWeight: tieneNuevos ? FontWeight.w800 : FontWeight.w700, color: kTextoOscuro),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                'Solicitud #$idSolicitud · ${item['descripcion_problema'] ?? ''}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 12.5, color: kTextoSuave),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        tieneNuevos
                                            ? Container(
                                                padding: const EdgeInsets.all(6),
                                                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                                decoration: const BoxDecoration(color: kCoral, shape: BoxShape.circle),
                                                child: Text(
                                                  '$sinLeer',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                                ),
                                              )
                                            : const Icon(Icons.chevron_right, color: kTextoSuave),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// Fecha de publicación legible: "hoy a las 09:42", "ayer a las 18:05" o "23 oct a las 10:30"
String _fechaPublicada(dynamic iso) {
  final dt = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
  if (dt == null) return '';
  final ahora = DateTime.now();
  final hoy = DateTime(ahora.year, ahora.month, ahora.day);
  final dia = DateTime(dt.year, dt.month, dt.day);
  final hora = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  final diff = hoy.difference(dia).inDays;
  if (diff == 0) return 'hoy a las $hora';
  if (diff == 1) return 'ayer a las $hora';
  const meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  return '${dt.day} ${meses[dt.month - 1]} a las $hora';
}

// Etiqueta de estado con icono de reloj y texto en mayúsculas (estilo Figma)
Widget _chipEstadoIcono(String texto, Color color, {IconData icono = Icons.schedule}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icono, size: 13, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            texto.toUpperCase(),
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.9),
          ),
        ),
      ],
    ),
  );
}

// --- DETALLE DE UNA SOLICITUD (PROFESIONAL): aceptar / rechazar y enviar cotización ---
class DetalleSolicitudProfesionalScreen extends StatefulWidget {
  final dynamic item;
  final String token;
  final String idUsuario; // para abrir el chat con el cliente
  const DetalleSolicitudProfesionalScreen({super.key, required this.item, required this.token, this.idUsuario = ''});

  @override
  State<DetalleSolicitudProfesionalScreen> createState() => _DetalleSolicitudProfesionalScreenState();
}

class _DetalleSolicitudProfesionalScreenState extends State<DetalleSolicitudProfesionalScreen> {
  // Copia local de la solicitud: se actualiza al iniciar o terminar el trabajo sin salir de la pantalla
  late dynamic _item = widget.item;
  bool _procesando = false;

  void _actualizarItem(dynamic cambios) {
    final nuevo = Map<String, dynamic>.from(_item as Map);
    nuevo.addAll(Map<String, dynamic>.from(cambios as Map));
    setState(() => _item = nuevo);
  }

  void _abrirChat() {
    final int id = (_item['id_solicitud'] as num).toInt();
    final String nombre = _item['usuarios'] != null ? (_item['usuarios']['nombre'] ?? 'Cliente').toString() : 'Cliente';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          titulo: nombre,
          idSolicitud: id,
          token: widget.token,
          idUsuarioActual: widget.idUsuario,
        ),
      ),
    );
  }

  // El profesional empieza el trabajo (el cliente ya aceptó la cotización)
  Future<void> _iniciarTrabajo() async {
    if (_procesando) return;
    setState(() => _procesando = true);
    try {
      final int id = (_item['id_solicitud'] as num).toInt();
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$id/iniciar'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _actualizarItem(jsonDecode(response.body)['solicitud']);
        _snack(context, 'Trabajo iniciado. ¡Mucho éxito!', color: kEstadoVerde);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión al iniciar el trabajo', color: kEstadoRojo);
    }
    if (mounted) setState(() => _procesando = false);
  }

  // El profesional termina el trabajo: queda pendiente de que el cliente lo verifique
  Future<void> _terminarTrabajo() async {
    if (_procesando) return;
    final nota = await _pedirTexto(
      context,
      etiqueta: 'CIERRE DEL TRABAJO',
      titulo: 'Trabajo terminado',
      subtitulo: 'El cliente recibirá un aviso para verificar que todo quedó en orden y calificar tu trabajo.',
      campo: 'Nota para el cliente (opcional)',
      hint: 'Ej. Se cambió el sello de la llave y se probó sin fugas.',
      boton: 'Marcar como terminado',
      icono: Icons.task_alt,
    );
    if (nota == null || !mounted) return;

    setState(() => _procesando = true);
    try {
      final int id = (_item['id_solicitud'] as num).toInt();
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$id/terminar'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'nota': nota}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _actualizarItem(jsonDecode(response.body)['solicitud']);
        _snack(context, 'Listo. El cliente verificará el trabajo y lo calificará.', color: kEstadoVerde);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión al terminar el trabajo', color: kEstadoRojo);
    }
    if (mounted) setState(() => _procesando = false);
  }

  // Proponer un nuevo precio durante el trabajo; el cliente debe aceptarlo para continuar
  Future<void> _proponerAjuste() async {
    if (_procesando) return;
    final String clienteNombre =
        _item['usuarios'] != null ? (_item['usuarios']['nombre'] ?? 'El cliente').toString() : 'El cliente';
    final resultado = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DialogoCotizacion(
        clienteNombre: clienteNombre,
        esAjuste: true,
        precioActual: double.tryParse((_item['precio_cotizacion'] ?? '').toString()),
      ),
    );
    if (resultado == null || !mounted) return;

    setState(() => _procesando = true);
    try {
      final int id = (_item['id_solicitud'] as num).toInt();
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$id/ajuste'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'precio': resultado['precio'], 'motivo': resultado['detalle']}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _actualizarItem(jsonDecode(response.body)['solicitud']);
        _snack(context, 'Nuevo precio enviado. El trabajo continúa cuando el cliente lo acepte.', color: kEstadoVerde);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión al enviar el nuevo precio', color: kEstadoRojo);
    }
    if (mounted) setState(() => _procesando = false);
  }

  Widget _botonModificarPrecio() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: kCoral,
            side: const BorderSide(color: kCoral),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: const Icon(Icons.request_quote_outlined, size: 20),
          label: const Text('Modificar cotización', style: TextStyle(fontWeight: FontWeight.w700)),
          onPressed: _procesando ? null : _proponerAjuste,
        ),
      ),
    );
  }

  // Aviso con la última respuesta del cliente a un cambio de precio
  Widget _avisoRespuestaAjuste(dynamic item) {
    final r = (item['ajuste_respuesta'] ?? '').toString();
    if (r == 'rechazado') {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: _cajaInfo(Icons.cancel_outlined, kEstadoRojo,
            'El cliente rechazó el nuevo precio de ${_dinero(item['precio_propuesto'])}. Se mantiene ${_dinero(item['precio_cotizacion'])}.'),
      );
    }
    if (r == 'aceptado') {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: _cajaInfo(Icons.check_circle_outline, kEstadoVerde,
            'El cliente aceptó el nuevo precio. Ahora es ${_dinero(item['precio_cotizacion'])}.'),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _botonChat() {
    if (widget.idUsuario.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: kVerde,
            side: const BorderSide(color: kVerde),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: const Icon(Icons.chat_bubble_outline, size: 20),
          label: const Text('Abrir chat con el cliente', style: TextStyle(fontWeight: FontWeight.w700)),
          onPressed: _abrirChat,
        ),
      ),
    );
  }

  // Aceptar o rechazar la solicitud del cliente. Al aceptar, se pide la cotización de inmediato.
  Future<void> _responderSolicitud(dynamic item, String estado) async {
    final int idSolicitud = (item['id_solicitud'] as num).toInt();
    try {
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$idSolicitud/estado'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'estado': estado}),
      );

      if (!mounted) return;
      if (response.statusCode == 200) {
        _snack(
          context,
          estado == 'aceptado' ? '¡Solicitud aceptada! Ahora envía tu cotización al cliente.' : 'Solicitud rechazada',
          color: estado == 'aceptado' ? kEstadoVerde : kEstadoRojo,
        );
        if (estado == 'aceptado') {
          await _abrirCotizacion(item);
        }
        // El estado de la solicitud cambió: volvemos a la lista para que se actualice
        if (mounted) Navigator.pop(context, true);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error al responder la solicitud', color: kEstadoRojo);
    }
  }

  // Ventana para escribir el precio y el detalle de la cotización.
  // Si se envía con éxito, vuelve a la lista (la pantalla se cierra).
  Future<void> _abrirCotizacion(dynamic item, {bool cerrarAlEnviar = false}) async {
    final int idSolicitud = (item['id_solicitud'] as num).toInt();
    final String clienteNombre =
        item['usuarios'] != null ? (item['usuarios']['nombre'] ?? 'el cliente').toString() : 'el cliente';

    final resultado = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DialogoCotizacion(clienteNombre: clienteNombre),
    );

    if (!mounted) return;
    if (resultado == null) {
      _snack(context, 'Puedes enviar la cotización cuando quieras desde esta pantalla.', color: kVerde);
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('$kBaseUrl/solicitudes/$idSolicitud/cotizacion'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'precio': resultado['precio'], 'detalle': resultado['detalle']}),
      );

      if (!mounted) return;
      if (response.statusCode == 200) {
        _snack(context, 'Cotización enviada. Espera la respuesta del cliente.', color: kEstadoVerde);
        if (cerrarAlEnviar && mounted) Navigator.pop(context, true);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión al enviar la cotización', color: kEstadoRojo);
    }
  }

  Widget _etiquetaEstado(String estado) {
    switch (estado) {
      case 'pendiente':
        return _chipEstadoIcono('Nueva solicitud', kCoral, icono: Icons.notifications_none);
      case 'aceptado':
        return _chipEstadoIcono('Por cotizar', kEstadoAzul);
      case 'cotizacion_rechazada':
        return _chipEstadoIcono('Cotización rechazada', kEstadoRojo, icono: Icons.cancel_outlined);
      case 'cotizado':
        return _chipEstadoIcono('Esperando al cliente', kEstadoVerde);
      case 'confirmado':
        return _chipEstadoIcono('Por iniciar', kEstadoAzul, icono: Icons.play_circle_outline);
      case 'en_curso':
        return _chipEstadoIcono('En curso', kEstadoVerde, icono: Icons.construction);
      case 'por_verificar':
        return _chipEstadoIcono('Por verificar', kCoral, icono: Icons.hourglass_top);
      case 'ajuste_pendiente':
        return _chipEstadoIcono('Nuevo precio', kCoral, icono: Icons.request_quote_outlined);
      case 'completado':
        return _chipEstadoIcono('Completado', kEstadoVerde, icono: Icons.check_circle_outline);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _bloqueAcciones(dynamic item, String estado) {
    final String detalle = (item['detalle_cotizacion'] ?? '').toString().trim();

    switch (estado) {
      case 'pendiente':
        return Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kEstadoRojo,
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: kEstadoRojo),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => _responderSolicitud(item, 'rechazado'),
                  child: const Text('Rechazar', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kVerde,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => _responderSolicitud(item, 'aceptado'),
                  child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        );

      case 'aceptado':
        return Column(
          children: [
            _cajaInfo(Icons.info_outline, kEstadoAzul,
                'Aceptaste esta solicitud. Envía tu cotización para que el cliente pueda confirmarla.'),
            const SizedBox(height: 14),
            _botonCoral('Enviar cotización', false, () => _abrirCotizacion(item, cerrarAlEnviar: true)),
          ],
        );

      case 'cotizacion_rechazada':
        return Column(
          children: [
            _cajaInfo(Icons.cancel_outlined, kEstadoRojo,
                'El cliente rechazó tu cotización de ${_dinero(item['precio_cotizacion'])}. Puedes enviarle una nueva.'),
            const SizedBox(height: 14),
            _botonCoral('Enviar nueva cotización', false, () => _abrirCotizacion(item, cerrarAlEnviar: true)),
          ],
        );

      case 'cotizado':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE6F0EA),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'COTIZACIÓN ENVIADA',
                style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3),
              ),
              const SizedBox(height: 6),
              Text(_dinero(item['precio_cotizacion']), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: kVerde)),
              if (detalle.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(detalle, style: const TextStyle(fontSize: 13.5, height: 1.4, color: kTextoOscuro)),
              ],
              const SizedBox(height: 12),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.hourglass_top, size: 16, color: kVerde),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Esperando la respuesta del cliente. Cuando la acepte se habilitará el chat.',
                      style: TextStyle(fontSize: 12.5, color: kTextoSuave, height: 1.4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case 'confirmado':
        return Column(
          children: [
            _cajaInfo(Icons.check_circle_outline, kEstadoVerde,
                'El cliente aceptó tu cotización de ${_dinero(item['precio_cotizacion'])}. Cuando empieces, marca el inicio del trabajo.'),
            _avisoRespuestaAjuste(item),
            const SizedBox(height: 14),
            _botonCoral('Iniciar trabajo', _procesando, _procesando ? null : _iniciarTrabajo),
            _botonModificarPrecio(),
            _botonChat(),
          ],
        );

      case 'en_curso':
        final inicio = _fechaPublicada(item['fecha_inicio']);
        final motivo = (item['motivo_rechazo_cierre'] ?? '').toString().trim();
        return Column(
          children: [
            _cajaInfo(Icons.construction, kEstadoAzul,
                'Trabajo en curso${inicio.isNotEmpty ? ' desde $inicio' : ''}. Cuando termines, márcalo para que el cliente lo verifique.'),
            if (motivo.isNotEmpty) ...[
              const SizedBox(height: 10),
              _cajaInfo(Icons.info_outline, kCoral, 'El cliente indicó que aún falta: "$motivo"'),
            ],
            _avisoRespuestaAjuste(item),
            const SizedBox(height: 14),
            _botonCoral('Marcar como terminado', _procesando, _procesando ? null : _terminarTrabajo),
            _botonModificarPrecio(),
            _botonChat(),
          ],
        );

      case 'ajuste_pendiente':
        return Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kCrema,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kCoral.withOpacity(0.45)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('NUEVO PRECIO PROPUESTO',
                      style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_dinero(item['precio_propuesto']),
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: kVerde)),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(_dinero(item['precio_cotizacion']),
                            style: const TextStyle(fontSize: 13, color: kTextoSuave, decoration: TextDecoration.lineThrough)),
                      ),
                    ],
                  ),
                  if ((item['detalle_propuesto'] ?? '').toString().trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text((item['detalle_propuesto']).toString(), style: const TextStyle(fontSize: 13.5, height: 1.4, color: kTextoOscuro)),
                  ],
                  const SizedBox(height: 12),
                  const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.hourglass_top, size: 16, color: kCoral),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('Esperando que el cliente lo acepte. El trabajo continúa cuando responda.',
                            style: TextStyle(fontSize: 12.5, color: kTextoSuave, height: 1.4)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _botonChat(),
          ],
        );

      case 'por_verificar':
        final fin = _fechaPublicada(item['fecha_fin']);
        return Column(
          children: [
            _cajaInfo(Icons.hourglass_top, kCoral,
                'Marcaste el trabajo como terminado${fin.isNotEmpty ? ' $fin' : ''}. Esperando que el cliente lo verifique y lo califique.'),
            _botonChat(),
          ],
        );

      case 'completado':
        final fecha = _fechaCorta(item['fecha_completado']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cajaInfo(Icons.verified_outlined, kEstadoVerde,
                'Trabajo completado${fecha.isNotEmpty ? ' el $fecha' : ''}. Precio acordado: ${_dinero(item['precio_cotizacion'])}.'),
            if (item['resena'] != null) ...[
              const SizedBox(height: 12),
              _bloqueResena(context, item['resena']),
            ],
          ],
        );

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _filaInfo(IconData icono, Widget contenido) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icono, size: 20, color: kTextoSuave),
        const SizedBox(width: 10),
        Expanded(child: contenido),
      ],
    );
  }

  Widget _tarjetaSolicitud(dynamic item) {
    final String estado = (item['estado'] ?? 'pendiente').toString();
    final String clienteNombre = item['usuarios'] != null ? (item['usuarios']['nombre'] ?? 'Cliente').toString() : 'Cliente';
    final String clienteTel = item['usuarios'] != null ? (item['usuarios']['telefono'] ?? 'N/A').toString() : 'N/A';
    final direccion = item['direccion_texto'] ?? 'Dirección sin especificar';
    final double? latSol = (item['latitud'] as num?)?.toDouble();
    final double? lngSol = (item['longitud'] as num?)?.toDouble();
    final String publicada = _fechaPublicada(item['fecha_creacion']);

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFEAE6DD)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: const Color(0xFFDDEBF0), borderRadius: BorderRadius.circular(16)),
                child: const Icon(Icons.build_outlined, color: kEstadoAzul, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: _etiquetaEstado(estado)),
                    const SizedBox(height: 12),
                    Text(
                      clienteNombre,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.2),
                    ),
                    if (publicada.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Publicada $publicada', style: const TextStyle(fontSize: 13, color: kTextoSuave)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Divider(height: 1, color: Color(0xFFEFEBE3)),
          const SizedBox(height: 16),
          _filaInfo(
            Icons.home_outlined,
            DireccionSolicitud(
              textoGuardado: direccion.toString(),
              lat: latSol,
              lng: lngSol,
              style: const TextStyle(fontSize: 14, color: kTextoOscuro, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 10),
          _filaInfo(
            Icons.phone_outlined,
            Text('Tel: $clienteTel', style: const TextStyle(fontSize: 14, color: kTextoOscuro, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFEFEBE3)),
          const SizedBox(height: 16),
          Text(
            (item['descripcion_problema'] ?? '').toString(),
            style: const TextStyle(fontSize: 15, height: 1.5, color: kTextoOscuro),
          ),
          if (latSol != null && lngSol != null) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: MapaUbicacionMini(punto: LatLng(latSol, lngSol), alto: 150),
            ),
          ],
          const SizedBox(height: 18),
          _bloqueAcciones(item, estado),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _encabezadoPantalla(context, 'SOLICITUD #${item['id_solicitud']}', 'Detalle', 'Revisa los datos y responde al cliente.'),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                child: _tarjetaSolicitud(item),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Ventana donde el profesional escribe el precio y el detalle de su cotización
class DialogoCotizacion extends StatefulWidget {
  final String clienteNombre;
  final bool esAjuste;          // true: modificar una cotización ya aceptada
  final double? precioActual;   // precio vigente (solo en ajustes)
  const DialogoCotizacion({super.key, required this.clienteNombre, this.esAjuste = false, this.precioActual});

  @override
  State<DialogoCotizacion> createState() => _DialogoCotizacionState();
}

class _DialogoCotizacionState extends State<DialogoCotizacion> {
  final TextEditingController _precioController = TextEditingController();
  final TextEditingController _detalleController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _precioController.dispose();
    _detalleController.dispose();
    super.dispose();
  }

  void _enviar() {
    final precio = double.tryParse(_precioController.text.trim().replaceAll(',', '.'));
    if (precio == null || precio <= 0) {
      setState(() => _error = 'Escribe un precio válido, mayor a 0.');
      return;
    }
    if (precio > 1000000) {
      setState(() => _error = 'El precio no puede ser mayor a 1,000,000.');
      return;
    }
    if (widget.esAjuste) {
      if (widget.precioActual != null && (widget.precioActual! - precio).abs() < 0.005) {
        setState(() => _error = 'El nuevo precio es igual al actual.');
        return;
      }
      if (_detalleController.text.trim().length < 3) {
        setState(() => _error = 'Explica al cliente por qué cambia el precio.');
        return;
      }
    }
    Navigator.pop(context, {'precio': precio, 'detalle': _detalleController.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    final borde = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE3DFD6)),
    );
    final bordeFoco = borde.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4));

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.request_quote_outlined, color: kVerde, size: 26),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: kCrema, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.close, color: kTextoOscuro, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              widget.esAjuste ? 'MODIFICAR COTIZACIÓN' : 'NUEVA COTIZACIÓN',
              style: TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              widget.esAjuste ? 'Propón un nuevo precio' : 'Envía tu propuesta',
              style: TextStyle(color: kTextoOscuro, fontSize: 28, fontWeight: FontWeight.w600, height: 1.15),
            ),
            const SizedBox(height: 10),
            Text(
              widget.esAjuste
                  ? '${widget.clienteNombre} deberá aceptar el nuevo precio para que el trabajo continúe.${widget.precioActual != null ? ' Precio actual: ${_dinero(widget.precioActual)}.' : ''}'
                  : 'Para ${widget.clienteNombre}. Sé claro con el precio y con lo que incluye.',
              style: const TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 22),
            Text(widget.esAjuste ? 'Nuevo precio total (MXN)' : 'Precio total (MXN)', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _precioController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: kTextoOscuro, fontSize: 16, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: '0.00',
                hintStyle: const TextStyle(color: kTextoSuave, fontSize: 15),
                prefixIcon: const Icon(Icons.attach_money, color: kTextoSuave),
                prefixIconColor: kTextoSuave,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                enabledBorder: _error != null ? borde.copyWith(borderSide: const BorderSide(color: kCoral)) : borde,
                focusedBorder: _error != null ? borde.copyWith(borderSide: const BorderSide(color: kCoral, width: 1.4)) : bordeFoco,
                border: borde,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(_error!, style: const TextStyle(color: kCoral, fontSize: 12.5)),
              ),
            const SizedBox(height: 18),
            Text(widget.esAjuste ? 'Motivo del cambio' : 'Qué incluye / tiempo estimado', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _detalleController,
              minLines: 4,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: widget.esAjuste ? 'Ej. Al abrir la pared encontré más daño del esperado y se necesita más material.' : 'Ej. Mano de obra y materiales. Tiempo: 2 horas.',
                hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(16),
                enabledBorder: borde,
                focusedBorder: bordeFoco,
                border: borde,
              ),
            ),
            const SizedBox(height: 22),
            _botonCoral(widget.esAjuste ? 'Enviar nuevo precio' : 'Enviar cotización', false, _enviar),
          ],
        ),
      ),
    );
  }
}

// --- PANTALLA DE SOLICITUDES DEL CLIENTE (estado y cotizaciones) ---
class MisSolicitudesScreen extends StatefulWidget {
  final String token;
  final String idUsuario;
  const MisSolicitudesScreen({super.key, required this.token, required this.idUsuario});

  @override
  State<MisSolicitudesScreen> createState() => _MisSolicitudesScreenState();
}

class _MisSolicitudesScreenState extends State<MisSolicitudesScreen> {
  bool _cargando = true;
  List<dynamic> _solicitudes = [];
  Timer? _timer;
  int? _respondiendoId;

  @override
  void initState() {
    super.initState();
    _cargarSolicitudes();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _cargarSolicitudes(silencioso: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _cargarSolicitudes({bool silencioso = false}) async {
    if (!silencioso) setState(() => _cargando = true);
    try {
      final response = await http.get(
        Uri.parse('$kBaseUrl/solicitudes/mias'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );

      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _solicitudes = data['solicitudes'] ?? []);
      } else if (!silencioso) {
        _snack(context, _detalleError(response.body), color: Colors.red);
      }
    } catch (e) {
      if (mounted && !silencioso) _snack(context, 'Error al cargar tus solicitudes', color: Colors.red);
    }
    if (mounted) setState(() => _cargando = false);
  }

  void _abrirChat(dynamic item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          titulo: (item['nombre_profesional'] ?? 'Profesional').toString(),
          idSolicitud: (item['id_solicitud'] as num).toInt(),
          token: widget.token,
          idUsuarioActual: widget.idUsuario,
        ),
      ),
    ).then((_) => _cargarSolicitudes(silencioso: true));
  }

  // Aceptar o rechazar la cotización que mandó el profesional
  Future<void> _responderCotizacion(dynamic item, bool aceptar) async {
    if (_respondiendoId != null) return;
    final int idSolicitud = (item['id_solicitud'] as num).toInt();
    setState(() => _respondiendoId = idSolicitud);

    try {
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$idSolicitud/cotizacion'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'aceptar': aceptar}),
      );

      if (!mounted) return;
      if (response.statusCode == 200) {
        _snack(
          context,
          aceptar ? '¡Cotización aceptada! Ya puedes chatear con el profesional.' : 'Cotización rechazada.',
          color: aceptar ? Colors.green : Colors.red,
        );
        await _cargarSolicitudes(silencioso: true);
        if (aceptar && mounted) _abrirChat(item);
      } else {
        _snack(context, _detalleError(response.body), color: Colors.red);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión al responder la cotización', color: Colors.red);
    } finally {
      if (mounted) setState(() => _respondiendoId = null);
    }
  }

  // Verificar el trabajo terminado y calificarlo (pantalla aparte)
  Future<void> _abrirCalificacion(dynamic item) async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => CalificarTrabajoScreen(item: item, token: widget.token)),
    );
    if (ok == true && mounted) await _cargarSolicitudes(silencioso: true);
  }

  // Aceptar o rechazar el nuevo precio propuesto por el profesional
  Future<void> _responderAjuste(dynamic item, bool aceptar) async {
    if (_respondiendoId != null) return;
    final int idSolicitud = (item['id_solicitud'] as num).toInt();
    setState(() => _respondiendoId = idSolicitud);
    try {
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$idSolicitud/ajuste/respuesta'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'aceptar': aceptar}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _snack(
          context,
          aceptar ? 'Aceptaste el nuevo precio. El trabajo continúa.' : 'Rechazaste el nuevo precio. Se mantiene el precio original.',
          color: aceptar ? kEstadoVerde : kEstadoRojo,
        );
        await _cargarSolicitudes(silencioso: true);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión', color: kEstadoRojo);
    }
    if (mounted) setState(() => _respondiendoId = null);
  }

  // El cliente avisa que el trabajo todavía no está terminado
  Future<void> _noTerminado(dynamic item) async {
    if (_respondiendoId != null) return;
    final int idSolicitud = (item['id_solicitud'] as num).toInt();

    final motivo = await _pedirTexto(
      context,
      etiqueta: 'VERIFICACIÓN',
      titulo: 'Aún falta algo',
      subtitulo: 'Cuéntale al profesional qué falta por terminar. Su trabajo seguirá en curso.',
      campo: '¿Qué falta o qué no quedó bien?',
      hint: 'Ej. Todavía gotea la llave del lavabo.',
      boton: 'Enviar aviso',
      obligatorio: true,
      icono: Icons.report_gmailerrorred_outlined,
    );
    if (motivo == null || !mounted) return;

    setState(() => _respondiendoId = idSolicitud);
    try {
      final response = await http.put(
        Uri.parse('$kBaseUrl/solicitudes/$idSolicitud/cierre-rechazado'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'motivo': motivo}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _snack(context, 'Avisamos al profesional que el trabajo aún no está terminado.', color: kEstadoVerde);
        await _cargarSolicitudes(silencioso: true);
      } else {
        _snack(context, _detalleError(response.body), color: kEstadoRojo);
      }
    } catch (e) {
      if (mounted) _snack(context, 'Error de conexión', color: kEstadoRojo);
    }
    if (mounted) setState(() => _respondiendoId = null);
  }

  Widget _etiquetaEstado(String estado) {
    switch (estado) {
      case 'pendiente':
        return _chipEstado('Enviada', kTextoSuave);
      case 'aceptado':
        return _chipEstado('En preparación', kEstadoAzul);
      case 'cotizado':
        return _chipEstado('Cotización recibida', kCoral);
      case 'cotizacion_rechazada':
        return _chipEstado('Cotización rechazada', kEstadoRojo);
      case 'confirmado':
        return _chipEstado('Confirmado', kEstadoVerde);
      case 'en_curso':
        return _chipEstado('En curso', kEstadoAzul);
      case 'por_verificar':
        return _chipEstado('Por verificar', kCoral);
      case 'ajuste_pendiente':
        return _chipEstado('Nuevo precio', kCoral);
      case 'completado':
        return _chipEstado('Completado', kEstadoVerde);
      case 'rechazado':
        return _chipEstado('Rechazada', kEstadoRojo);
      default:
        return _chipEstado(estado, kTextoSuave);
    }
  }

  Widget _bloqueEstado(dynamic item, String estado) {
    final int id = (item['id_solicitud'] as num).toInt();
    final bool ocupado = _respondiendoId == id;
    final String detalle = (item['detalle_cotizacion'] ?? '').toString().trim();
    final String nombre = (item['nombre_profesional'] ?? 'El profesional').toString();
    final String motivoRechazo = (item['motivo_rechazo_cierre'] ?? '').toString().trim();
    final String nota = (item['nota_cierre'] ?? '').toString().trim();

    switch (estado) {
      case 'pendiente':
        return _cajaInfo(Icons.hourglass_top, kTextoSuave, 'Enviaste esta solicitud. Esperando que el profesional la acepte.');

      case 'aceptado':
        return _cajaInfo(Icons.edit_outlined, kEstadoAzul, 'El profesional aceptó tu solicitud y está preparando su cotización.');

      case 'cotizado':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCrema,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kCoral.withOpacity(0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'COTIZACIÓN RECIBIDA',
                style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3),
              ),
              const SizedBox(height: 6),
              Text(_dinero(item['precio_cotizacion']), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: kVerde)),
              if (detalle.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(detalle, style: const TextStyle(fontSize: 13.5, height: 1.4, color: kTextoOscuro)),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kEstadoRojo,
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: kEstadoRojo),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: ocupado ? null : () => _responderCotizacion(item, false),
                        child: const Text('Rechazar', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kVerde,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: ocupado ? null : () => _responderCotizacion(item, true),
                        child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case 'cotizacion_rechazada':
        return _cajaInfo(Icons.cancel_outlined, kEstadoRojo,
            'Rechazaste la cotización de ${_dinero(item['precio_cotizacion'])}. El profesional puede enviarte una nueva.');

      case 'confirmado':
        return Column(
          children: [
            _cajaInfo(Icons.check_circle_outline, kEstadoVerde,
                'Cotización aceptada: ${_dinero(item['precio_cotizacion'])}. $nombre iniciará el trabajo y te avisaremos aquí. Mientras tanto pueden chatear para coordinar.'),
            const SizedBox(height: 12),
            _botonCoral('Abrir chat', false, () => _abrirChat(item)),
          ],
        );

      case 'en_curso':
        final inicio = _fechaPublicada(item['fecha_inicio']);
        return Column(
          children: [
            _cajaInfo(Icons.construction, kEstadoAzul,
                '$nombre está trabajando en tu solicitud${inicio.isNotEmpty ? ' (inició $inicio)' : ''}. Te avisaremos cuando lo marque como terminado.'),
            if (motivoRechazo.isNotEmpty) ...[
              const SizedBox(height: 10),
              _cajaInfo(Icons.info_outline, kCoral, 'Le indicaste que aún faltaba: "$motivoRechazo"'),
            ],
            const SizedBox(height: 12),
            _botonCoral('Abrir chat', false, () => _abrirChat(item)),
          ],
        );

      case 'ajuste_pendiente':
        final String motivoAjuste = (item['detalle_propuesto'] ?? '').toString().trim();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCrema,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kCoral.withOpacity(0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CAMBIO DE PRECIO',
                  style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_dinero(item['precio_propuesto']),
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: kVerde)),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(_dinero(item['precio_cotizacion']),
                        style: const TextStyle(fontSize: 13, color: kTextoSuave, decoration: TextDecoration.lineThrough)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('$nombre propone modificar el precio acordado. El trabajo continúa cuando respondas.',
                  style: const TextStyle(fontSize: 13.5, height: 1.4, color: kTextoOscuro)),
              if (motivoAjuste.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('MOTIVO', style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
                const SizedBox(height: 4),
                Text(motivoAjuste, style: const TextStyle(fontSize: 13.5, height: 1.4, color: kTextoOscuro)),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kEstadoRojo,
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: kEstadoRojo),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: ocupado ? null : () => _responderAjuste(item, false),
                        child: const Text('Rechazar', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kVerde,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: ocupado ? null : () => _responderAjuste(item, true),
                        child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: () => _abrirChat(item),
                child: const Text('Hablar con el profesional', style: TextStyle(color: kTextoSuave, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        );

      case 'por_verificar':
        final fin = _fechaPublicada(item['fecha_fin']);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCrema,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kCoral.withOpacity(0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'TRABAJO TERMINADO',
                style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3),
              ),
              const SizedBox(height: 8),
              Text(
                '$nombre marcó el trabajo como terminado${fin.isNotEmpty ? ' $fin' : ''}. Revísalo y confirma si todo quedó en orden.',
                style: const TextStyle(fontSize: 14, height: 1.4, color: kTextoOscuro),
              ),
              if (nota.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('NOTA DEL PROFESIONAL',
                    style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
                const SizedBox(height: 4),
                Text(nota, style: const TextStyle(fontSize: 13.5, height: 1.4, color: kTextoOscuro)),
              ],
              const SizedBox(height: 16),
              _botonCoral('Confirmar y calificar', false, ocupado ? null : () => _abrirCalificacion(item)),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kEstadoRojo,
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: kEstadoRojo),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: ocupado ? null : () => _noTerminado(item),
                  child: const Text('Aún no está terminado', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: () => _abrirChat(item),
                  child: const Text('Hablar con el profesional', style: TextStyle(color: kTextoSuave, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        );

      case 'completado':
        final finCompletado = _fechaCorta(item['fecha_completado']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cajaInfo(Icons.verified_outlined, kEstadoVerde,
                'Trabajo completado${finCompletado.isNotEmpty ? ' el $finCompletado' : ''}. Precio acordado: ${_dinero(item['precio_cotizacion'])}.'),
            if (item['resena'] != null) ...[
              const SizedBox(height: 12),
              _bloqueResena(context, item['resena'], titulo: 'TU CALIFICACIÓN'),
            ],
          ],
        );

      case 'rechazado':
        return _cajaInfo(Icons.block, kEstadoRojo, 'El profesional no pudo atender esta solicitud.');

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _tarjetaSolicitud(dynamic item) {
    final String estado = (item['estado'] ?? 'pendiente').toString();
    final String nombre = (item['nombre_profesional'] ?? 'Profesional').toString();
    final String oficio = (item['oficio'] ?? '').toString();
    final String inicial = nombre.isNotEmpty ? nombre[0].toUpperCase() : '?';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: _decoTarjeta(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                child: Text(inicial, style: const TextStyle(color: kVerde, fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombre, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: kTextoOscuro)),
                    if (oficio.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(oficio, style: const TextStyle(color: kCoral, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _etiquetaEstado(estado),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: Color(0xFFEFEBE3)),
          const SizedBox(height: 14),
          const Text(
            'TU PROBLEMA',
            style: TextStyle(fontSize: 11, color: kTextoSuave, fontWeight: FontWeight.w700, letterSpacing: 1.3),
          ),
          const SizedBox(height: 6),
          Text((item['descripcion_problema'] ?? '').toString(), style: const TextStyle(fontSize: 14.5, height: 1.4, color: kTextoOscuro)),
          const SizedBox(height: 16),
          _bloqueEstado(item, estado),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _encabezadoPantalla(context, 'SEGUIMIENTO', 'Mis solicitudes', 'Revisa el estado y responde a las cotizaciones.'),
            const SizedBox(height: 8),
            Expanded(
              child: _cargando
                  ? const Center(child: CircularProgressIndicator(color: kCoral))
                  : _solicitudes.isEmpty
                      ? _estadoVacio(Icons.handyman_outlined, 'Aún no has enviado solicitudes.\nBusca un profesional y solicita su servicio.')
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                          itemCount: _solicitudes.length,
                          itemBuilder: (context, index) => _tarjetaSolicitud(_solicitudes[index]),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// Fila "★ 4.9 (12) · 5 trabajos completados" para los perfiles profesionales
Widget _filaCalificacion(double? calificacion, int totalResenas, int completados) {
  return Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 6,
    runSpacing: 4,
    children: [
      if (calificacion != null && totalResenas > 0) ...[
        const Icon(Icons.star_rounded, size: 20, color: kEstrella),
        Text(calificacion.toStringAsFixed(1), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: kEstrella)),
        Text('($totalResenas)', style: const TextStyle(fontSize: 12.5, color: kTextoSuave)),
      ] else
        const Text('Sin calificaciones aún', style: TextStyle(fontSize: 12.5, color: kTextoSuave)),
      Text(
        '· $completados ${completados == 1 ? 'trabajo completado' : 'trabajos completados'}',
        style: const TextStyle(fontSize: 12.5, color: kTextoSuave),
      ),
    ],
  );
}

// --- GANANCIAS DEL PROFESIONAL ---
String _formatoDuracion(int segundos) {
  if (segundos <= 0) return '0 min';
  final int minutos = (segundos / 60).round();
  if (minutos < 1) return '< 1 min';
  final int dias = minutos ~/ (60 * 24);
  final int horas = (minutos % (60 * 24)) ~/ 60;
  final int mins = minutos % 60;
  if (dias > 0) return '$dias d${horas > 0 ? ' $horas h' : ''}';
  if (horas > 0) return '$horas h${mins > 0 ? ' $mins min' : ''}';
  return '$mins min';
}

String _dineroCorto(dynamic valor) {
  final n = double.tryParse(valor?.toString() ?? '') ?? 0;
  final partes = n.toStringAsFixed(2).split('.');
  final entero = partes[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return '\$$entero.${partes[1]}';
}

class GananciasScreen extends StatefulWidget {
  final String token;
  const GananciasScreen({super.key, required this.token});

  @override
  State<GananciasScreen> createState() => _GananciasScreenState();
}

class _GananciasScreenState extends State<GananciasScreen> {
  bool _cargando = true;
  bool _error = false;
  double _total = 0;
  int _trabajosCompletados = 0;
  int _segundos = 0;
  List<dynamic> _trabajos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = false;
    });
    try {
      final res = await http.get(
        Uri.parse('$kBaseUrl/profesionales/ganancias'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final r = data['resumen'] ?? {};
        setState(() {
          _total = double.tryParse((r['total_ganado'] ?? 0).toString()) ?? 0;
          _trabajosCompletados = int.tryParse((r['trabajos_completados'] ?? 0).toString()) ?? 0;
          _segundos = int.tryParse((r['segundos_trabajados'] ?? 0).toString()) ?? 0;
          _trabajos = data['trabajos'] ?? [];
        });
      } else {
        _error = true;
        _snack(context, _detalleError(res.body), color: kEstadoRojo);
      }
    } catch (e) {
      _error = true;
      if (mounted) _snack(context, 'Error de conexión al cargar tus ganancias', color: kEstadoRojo);
    }
    if (mounted) setState(() => _cargando = false);
  }

  Widget _tarjetaDato(IconData icono, Color fondo, Color tinta, String etiqueta, String valor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFEAE6DD)),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, 5))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(12)),
              child: Icon(icono, color: tinta, size: 22),
            ),
            const SizedBox(height: 14),
            Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            const SizedBox(height: 4),
            Text(valor, style: const TextStyle(color: kTextoOscuro, fontSize: 22, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _filaTrabajo(dynamic t, {required bool ultima}) {
    final String descripcion = (t['descripcion_problema'] ?? '').toString().trim();
    final String cliente = (t['cliente'] ?? 'Cliente').toString();
    final int seg = int.tryParse((t['segundos_trabajados'] ?? 0).toString()) ?? 0;
    final String fecha = _fechaCorta(t['fecha_completado']);
    final partes = [cliente, if (fecha.isNotEmpty) fecha, if (seg > 0) _formatoDuracion(seg)];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(border: ultima ? null : const Border(bottom: BorderSide(color: Color(0xFFEFEBE3)))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.check_circle_outline, color: kEstadoVerde, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  descripcion.isEmpty ? 'Solicitud #${t['id_solicitud']}' : descripcion,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: kTextoOscuro, height: 1.3),
                ),
                const SizedBox(height: 4),
                Text(partes.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: kTextoSuave)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text('+${_dineroCorto(t['monto'])}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: kVerde)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: RefreshIndicator(
          color: kCoral,
          onRefresh: _cargar,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              _encabezadoPantalla(context, 'TU DINERO', 'Ganancias', 'Lo que has ganado con tus trabajos completados.'),
              if (_cargando)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 80),
                  child: Center(child: CircularProgressIndicator(color: kCoral)),
                )
              else if (_error)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      _estadoVacio(Icons.cloud_off_outlined, 'No pudimos cargar tus ganancias.'),
                      TextButton(onPressed: _cargar, child: const Text('Reintentar', style: TextStyle(color: kCoral, fontWeight: FontWeight.w700))),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: kVerde,
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [BoxShadow(color: kVerde.withOpacity(0.25), blurRadius: 24, offset: const Offset(0, 12))],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(color: kCoral.withOpacity(0.3), shape: BoxShape.circle),
                                  alignment: Alignment.center,
                                  child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: kCoral, shape: BoxShape.circle)),
                                ),
                                const SizedBox(width: 10),
                                const Text('TOTAL GANADO',
                                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
                              ],
                            ),
                            const SizedBox(height: 18),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(_dineroCorto(_total),
                                  style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w700, height: 1.1)),
                            ),
                            const SizedBox(height: 6),
                            Text('MXN · según las cotizaciones aceptadas',
                                style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _tarjetaDato(Icons.check_circle_outline, const Color(0xFFDCEBE0), kEstadoVerde, 'TRABAJOS', '$_trabajosCompletados'),
                          const SizedBox(width: 14),
                          _tarjetaDato(Icons.schedule, const Color(0xFFDDEBF0), kEstadoAzul, 'TIEMPO TRABAJADO', _formatoDuracion(_segundos)),
                        ],
                      ),
                      const SizedBox(height: 26),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(color: const Color(0xFFEAE6DD)),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('DESGLOSE',
                                style: TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                            const SizedBox(height: 10),
                            const Text('Ingresos por trabajo', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: kTextoOscuro)),
                            const SizedBox(height: 8),
                            if (_trabajos.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  'Aún no tienes trabajos completados. Cuando un cliente verifique y califique un trabajo, aparecerá aquí con su monto.',
                                  style: TextStyle(color: kTextoSuave, fontSize: 14, height: 1.4),
                                ),
                              )
                            else
                              for (int i = 0; i < _trabajos.length; i++) _filaTrabajo(_trabajos[i], ultima: i == _trabajos.length - 1),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- PERFIL PROFESIONAL: vista del perfil + edición (oficio, ubicación, descripción y fotos) ---
class EditarPerfilProfesionalScreen extends StatefulWidget {
  final String token;
  final String nombreUsuario;
  const EditarPerfilProfesionalScreen({super.key, required this.token, this.nombreUsuario = ''});

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
  List<String> _urlsFotos = ['', '', '']; // fotos ya guardadas en el servidor
  String? _oficio;
  String _descripcionGuardada = '';
  LatLng? _ubicacion;
  String _direccionTexto = '';
  String? _idProfesional;
  double? _calificacion;
  int _totalResenas = 0;
  int _trabajosCompletados = 0;
  bool _editando = false;
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

  // Carga lo que el profesional ya tenía guardado (oficio, ubicación, descripción, fotos)
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
        // Las fotos se guardan siempre en la misma ruta; este parámetro evita ver una versión vieja en caché
        final version = DateTime.now().millisecondsSinceEpoch;
        String url(dynamic v) {
          final t = (v ?? '').toString();
          return t.isEmpty ? '' : '$t?v=$version';
        }

        if (!mounted) return;
        setState(() {
          _descripcionGuardada = (p['descripcion'] ?? '').toString();
          _descripcionController.text = _descripcionGuardada;
          _oficio = (oficioGuardado != null && _oficios.contains(oficioGuardado)) ? oficioGuardado : null;
          _ubicacion = (lat != null && lng != null) ? LatLng((lat as num).toDouble(), (lng as num).toDouble()) : null;
          _urlsFotos = [url(p['foto_1']), url(p['foto_2']), url(p['foto_3'])];
          _idProfesional = p['id_profesional']?.toString();
          _calificacion = (p['calificacion_promedio'] as num?)?.toDouble();
          _totalResenas = int.tryParse((p['total_resenas'] ?? 0).toString()) ?? 0;
          _trabajosCompletados = int.tryParse((p['trabajos_completados'] ?? 0).toString()) ?? 0;
          // Si todavía no registra profesión o ubicación, entra directo a editar
          if (_oficio == null || _ubicacion == null) _editando = true;
        });
        if (_ubicacion != null) _actualizarDireccion(_ubicacion!);
      }
    } catch (e) {
      debugPrint('Error al cargar perfil: $e');
    }

    if (mounted) setState(() => _cargandoPerfil = false);
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
        if (mounted) _snack(context, 'Activa el GPS de tu dispositivo.', color: kCoral);
        return;
      }
      var permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied) {
        permiso = await Geolocator.requestPermission();
      }
      if (permiso == LocationPermission.denied || permiso == LocationPermission.deniedForever) {
        if (mounted) _snack(context, 'Permiso de ubicación denegado. También puedes tocar el mapa para marcar tu casa.', color: kCoral);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _fijarUbicacion(LatLng(pos.latitude, pos.longitude), moverMapa: true);
    } catch (e) {
      if (mounted) _snack(context, 'No se pudo obtener tu ubicación: $e', color: kCoral);
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
      _snack(context, 'Selecciona a qué te dedicas.', color: kCoral);
      return;
    }
    if (_ubicacion == null) {
      _snack(context, 'Marca tu ubicación para que los clientes cercanos puedan encontrarte.', color: kCoral);
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
          _snack(context, 'Perfil guardado con éxito', color: kEstadoVerde);
          setState(() {
            _foto1 = null;
            _foto2 = null;
            _foto3 = null;
            _editando = false;
          });
          await _cargarPerfil(); // refresca la vista con lo recién guardado
        }
      } else {
        if (mounted) {
          _snack(context, 'Error (${response.statusCode}): ${_detalleError(response.body)}', color: kEstadoRojo);
        }
      }
    } catch (e) {
      if (mounted) {
        _snack(context, 'Error de conexión: $e', color: kCoral);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Cancela la edición y regresa a la vista del perfil (descarta cambios sin guardar)
  void _cancelarEdicion() {
    setState(() {
      _editando = false;
      _foto1 = null;
      _foto2 = null;
      _foto3 = null;
    });
    _cargarPerfil();
  }

  // ---------- Piezas de diseño ----------
  String get _iniciales {
    final partes = widget.nombreUsuario.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (partes.isEmpty) return '?';
    if (partes.length == 1) return partes[0][0].toUpperCase();
    return (partes[0][0] + partes[1][0]).toUpperCase();
  }

  Widget _tarjetaSeccion({String? etiqueta, required String titulo, required Widget child, String? subtitulo}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFEAE6DD)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (etiqueta != null) ...[
            Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            const SizedBox(height: 10),
          ],
          Text(titulo, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: kTextoOscuro)),
          if (subtitulo != null) ...[
            const SizedBox(height: 4),
            Text(subtitulo, style: const TextStyle(fontSize: 13, color: kTextoSuave, height: 1.35)),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  Widget _dato(String etiqueta, String valor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
        const SizedBox(height: 6),
        Text(valor, style: const TextStyle(color: kTextoOscuro, fontSize: 15.5, height: 1.4)),
      ],
    );
  }

  Widget _fotoRed(String url) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => Container(
        color: const Color(0xFFEFEBE3),
        child: const Icon(Icons.broken_image_outlined, color: kTextoSuave),
      ),
      loadingBuilder: (context, child, progreso) => progreso == null
          ? child
          : Container(
              color: const Color(0xFFEFEBE3),
              child: const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kCoral))),
            ),
    );
  }

  // ---------- Vista del perfil (solo lectura) ----------
  Widget _vistaPerfil() {
    final fotos = _urlsFotos.where((u) => u.isNotEmpty).toList();
    final zona = _ubicacion == null
        ? 'Aún no has marcado tu ubicación'
        : (_direccionTexto.isEmpty ? 'Ubicación marcada en el mapa' : _direccionTexto);

    return Column(
      children: [
        // Tarjeta principal
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xFFEAE6DD)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
          ),
          child: Column(
            children: [
              Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: kVerde, borderRadius: BorderRadius.circular(26)),
                child: Text(_iniciales, style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 18),
              Text(
                widget.nombreUsuario.isEmpty ? 'Profesional' : widget.nombreUsuario,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: kTextoOscuro),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(20)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.handyman_outlined, size: 14, color: kEstadoVerde),
                    const SizedBox(width: 6),
                    Text(
                      (_oficio ?? 'Sin especialidad').toUpperCase(),
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: kEstadoVerde, letterSpacing: 0.9),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _filaCalificacion(_calificacion, _totalResenas, _trabajosCompletados),
            ],
          ),
        ),
        // Información profesional
        _tarjetaSeccion(
          titulo: 'Información profesional',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _dato('ESPECIALIDAD', _oficio ?? 'Sin especificar'),
              const SizedBox(height: 18),
              _dato('ZONA DE TRABAJO', zona),
              const SizedBox(height: 18),
              _dato(
                'SOBRE MI TRABAJO',
                _descripcionGuardada.trim().isEmpty ? 'Aún no has escrito una descripción de tus servicios.' : _descripcionGuardada.trim(),
              ),
            ],
          ),
        ),
        // Portfolio
        _tarjetaSeccion(
          etiqueta: 'REFERENCIAS VISUALES',
          titulo: 'Portfolio de trabajos',
          child: fotos.isEmpty
              ? const Text(
                  'Aún no has agregado fotos. Toca "Editar perfil" para mostrar tu trabajo a los clientes.',
                  style: TextStyle(color: kTextoSuave, fontSize: 14, height: 1.4),
                )
              : LayoutBuilder(builder: (context, constraints) {
                  final lado = (constraints.maxWidth - 10) / 2;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final u in fotos)
                        SizedBox(
                          width: lado,
                          height: lado * 0.95,
                          child: ClipRRect(borderRadius: BorderRadius.circular(18), child: _fotoRed(u)),
                        ),
                    ],
                  );
                }),
        ),
        // Reseñas de clientes
        if (_idProfesional != null) SeccionResenas(idProfesional: _idProfesional!, token: widget.token),
      ],
    );
  }

  // ---------- Formulario de edición ----------
  Widget _selectorFoto(int numero, XFile? archivo) {
    final String url = _urlsFotos[numero - 1];
    return Expanded(
      child: AspectRatio(
        aspectRatio: 1,
        child: InkWell(
          onTap: () => _seleccionarImagen(numero),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              color: kCrema,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE3DFD6)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (archivo != null)
                    (kIsWeb ? Image.network(archivo.path, fit: BoxFit.cover) : Image.file(File(archivo.path), fit: BoxFit.cover))
                  else if (url.isNotEmpty)
                    _fotoRed(url)
                  else
                    const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_outlined, color: kTextoSuave, size: 24),
                        SizedBox(height: 4),
                        Text('Añadir', style: TextStyle(color: kTextoSuave, fontSize: 11.5)),
                      ],
                    ),
                  if (archivo != null || url.isNotEmpty)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: const Icon(Icons.edit_outlined, size: 14, color: kTextoOscuro),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectorUbicacion() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 230,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
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
                      child: const Icon(Icons.location_on, color: kCoral, size: 44),
                    ),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: kVerde,
              side: const BorderSide(color: kVerde),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _obteniendoGps ? null : _usarMiUbicacion,
            icon: _obteniendoGps
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kVerde))
                : const Icon(Icons.my_location),
            label: const Text('Usar mi ubicación actual', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _ubicacion == null
              ? 'Toca el mapa para marcar dónde vives.'
              : (_direccionTexto.isEmpty ? 'Ubicación marcada.' : 'Ubicación marcada: $_direccionTexto'),
          style: TextStyle(fontSize: 12.5, color: _ubicacion == null ? kEstadoRojo : kEstadoVerde, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Los clientes verán tu pin en el mapa. Si prefieres no mostrar tu casa exacta, marca un punto cercano (por ejemplo, la esquina de tu colonia).',
          style: TextStyle(fontSize: 11.5, color: kTextoSuave, height: 1.35),
        ),
      ],
    );
  }

  Widget _formularioEdicion() {
    final borde = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE3DFD6)),
    );
    final bordeFoco = borde.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4));
    final bool puedeCancelar = _oficio != null && _ubicacion != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tarjetaSeccion(
          titulo: '¿A qué te dedicas?',
          child: DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _oficio,
            isExpanded: true,
            icon: const Icon(Icons.keyboard_arrow_down, color: kTextoOscuro),
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(14),
            hint: const Text('Selecciona tu especialidad', style: TextStyle(color: kTextoOscuro, fontSize: 14.5, fontWeight: FontWeight.w600)),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.handyman_outlined, color: kTextoSuave),
              prefixIconColor: kTextoSuave,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              enabledBorder: borde,
              focusedBorder: bordeFoco,
              border: borde,
            ),
            items: _oficios
                .map((o) => DropdownMenuItem(value: o, child: Text(o, style: const TextStyle(fontSize: 14.5, color: kTextoOscuro))))
                .toList(),
            onChanged: (v) => setState(() => _oficio = v),
          ),
        ),
        _tarjetaSeccion(
          titulo: 'Tu ubicación',
          subtitulo: 'Sirve para que los clientes de tu zona te encuentren.',
          child: _buildSelectorUbicacion(),
        ),
        _tarjetaSeccion(
          titulo: 'Descripción de tus servicios',
          child: TextField(
            controller: _descripcionController,
            minLines: 4,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Explica tu experiencia, especialidades, garantías o lo que te destaca...',
              hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(16),
              enabledBorder: borde,
              focusedBorder: bordeFoco,
              border: borde,
            ),
          ),
        ),
        _tarjetaSeccion(
          etiqueta: 'REFERENCIAS VISUALES',
          titulo: 'Fotos de tus trabajos',
          subtitulo: 'Toca un recuadro para elegir una foto de tu galería.',
          child: Row(
            children: [
              _selectorFoto(1, _foto1),
              const SizedBox(width: 10),
              _selectorFoto(2, _foto2),
              const SizedBox(width: 10),
              _selectorFoto(3, _foto3),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _botonCoral('Guardar perfil', _isLoading, _isLoading ? null : _guardarPerfil),
        if (puedeCancelar)
          Center(
            child: TextButton(
              onPressed: _isLoading ? null : _cancelarEdicion,
              child: const Text('Cancelar', style: TextStyle(color: kTextoSuave, fontWeight: FontWeight.w700)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: _cargandoPerfil
            ? const Center(child: CircularProgressIndicator(color: kCoral))
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFEAE6DD)),
                        ),
                        child: const Icon(Icons.arrow_back, color: kTextoOscuro, size: 20),
                      ),
                    ),
                        _botonAyuda(context),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _editando ? 'EDITAR PERFIL' : 'TU CUENTA',
                                style: const TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _editando ? 'Tu información' : 'Perfil profesional',
                                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _editando
                                    ? 'Registra a qué te dedicas y dónde trabajas para que los clientes te encuentren.'
                                    : 'Gestiona tu información y añade referencias de tus trabajos.',
                                style: const TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                        if (!_editando) ...[
                          const SizedBox(width: 12),
                          Material(
                            color: const Color(0xFFE6F0EA),
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => setState(() => _editando = true),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.edit_outlined, size: 16, color: kVerde),
                                    SizedBox(width: 8),
                                    Text('Editar\nperfil', style: TextStyle(color: kVerde, fontSize: 13.5, fontWeight: FontWeight.w800, height: 1.25)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                    _editando ? _formularioEdicion() : _vistaPerfil(),
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
  final String? descripcionInicial; // Texto escrito en el pop-up "Nueva solicitud"
  final String token;
  final String idUsuario;
  const MapaServiciosScreen({super.key, this.busquedaInicial, this.descripcionInicial, required this.token, required this.idUsuario});

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
          descripcionInicial: widget.descripcionInicial,
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

// --- PANTALLA COMPLETA DE DETALLE DEL PROFESIONAL (la ve el cliente y desde aquí envía la solicitud) ---
class PerfilProfesionalDetalleScreen extends StatefulWidget {
  final dynamic profesional;
  final LatLng? posicionCliente;
  final String? descripcionInicial;
  final String token;
  final String idUsuario;

  const PerfilProfesionalDetalleScreen({
    super.key, 
    required this.profesional, 
    this.posicionCliente,
    this.descripcionInicial,
    required this.token,
    required this.idUsuario,
  });

  @override
  State<PerfilProfesionalDetalleScreen> createState() => _PerfilProfesionalDetalleScreenState();
}

class _PerfilProfesionalDetalleScreenState extends State<PerfilProfesionalDetalleScreen> {
  late final TextEditingController _problemaController =
      TextEditingController(text: widget.descripcionInicial ?? '');
  bool _enviandoSolicitud = false;

  @override
  void dispose() {
    _problemaController.dispose();
    super.dispose();
  }

  Future<String> _obtenerDireccionTexto(double lat, double lng) async {
    final direccion = await obtenerDireccionLegible(lat, lng);
    return direccion ?? 'Coordenadas: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }

  // Panel inferior donde el cliente describe su problema y envía la solicitud
  void _mostrarModalSolicitud(BuildContext context) async {
    if (widget.posicionCliente == null) {
      _snack(context, 'No se tiene la ubicación actual del GPS.', color: kCoral);
      return;
    }

    _snack(context, 'Obteniendo tu dirección actual...', color: kVerde);
    String direccionCalculada = await _obtenerDireccionTexto(
      widget.posicionCliente!.latitude, 
      widget.posicionCliente!.longitude
    );

    if (!mounted) return;

    final String nombreProfesional = (widget.profesional['usuarios']?['nombre'] ?? 'El profesional').toString();
    final bordeCampo = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE3DFD6)),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCrema,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (modalContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(modalContext).viewInsets.bottom + 20,
            left: 22,
            right: 22,
            top: 22,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(14)),
                      child: const Icon(Icons.build_outlined, color: kVerde, size: 26),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(modalContext),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFEAE6DD)),
                        ),
                        child: const Icon(Icons.close, color: kTextoOscuro, size: 20),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'SOLICITAR SERVICIO',
                  style: TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Describe tu problema',
                  style: TextStyle(color: kTextoOscuro, fontSize: 28, fontWeight: FontWeight.w600, height: 1.15),
                ),
                const SizedBox(height: 10),
                Text(
                  '$nombreProfesional recibirá tu solicitud y te enviará una cotización.',
                  style: const TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFEAE6DD)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.home_outlined, color: kTextoSuave, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'TU DIRECCIÓN',
                              style: TextStyle(color: kTextoSuave, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.3),
                            ),
                            const SizedBox(height: 4),
                            Text(direccionCalculada, style: const TextStyle(fontSize: 14, color: kTextoOscuro, height: 1.35)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: MapaUbicacionMini(punto: widget.posicionCliente!, alto: 160),
                ),
                const SizedBox(height: 20),
                const Text('Describe el problema', style: TextStyle(color: kTextoOscuro, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                TextField(
                  controller: _problemaController,
                  minLines: 4,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Ej. Hay una fuga debajo del fregadero...',
                    hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.all(16),
                    enabledBorder: bordeCampo,
                    border: bordeCampo,
                    focusedBorder: bordeCampo.copyWith(borderSide: const BorderSide(color: kVerde, width: 1.4)),
                  ),
                ),
                const SizedBox(height: 22),
                StatefulBuilder(
                  builder: (builderContext, setModalState) {
                    return _botonCoral(
                      'Enviar solicitud', 
                      _enviandoSolicitud, 
                      _enviandoSolicitud ? null : () async {
                        if (_problemaController.text.trim().isEmpty) {
                          _snack(context, 'Escribe la descripción de tu problema.', color: kCoral);
                          return;
                        }

                        bool modalCerrado = false;
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
                            _problemaController.clear();
                            if (modalContext.mounted) {
                              modalCerrado = true;
                              Navigator.pop(modalContext); // Cierra el panel
                            }
                            // El aviso se muestra con el contexto de la PANTALLA, no el del panel ya cerrado
                            if (mounted) {
                              _snack(context, '¡Solicitud enviada! Espera a que el profesional la acepte.', color: kEstadoVerde);
                            }
                          } else {
                            if (mounted) _snack(context, _detalleError(response.body), color: kEstadoRojo);
                          }
                        } catch (e) {
                          if (mounted) _snack(context, 'Error de conexión', color: kEstadoRojo);
                        } finally {
                          _enviandoSolicitud = false;
                          if (!modalCerrado && modalContext.mounted) {
                            setModalState(() {});
                          }
                        }
                      }
                    );
                  }
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Foto a pantalla completa (con zoom)
  void _verFoto(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: InkWell(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 20, color: kTextoOscuro),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tarjetaSeccion({String? etiqueta, required String titulo, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFEAE6DD)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (etiqueta != null) ...[
            Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            const SizedBox(height: 10),
          ],
          Text(titulo, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: kTextoOscuro)),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  Widget _dato(String etiqueta, String valor, {bool suave = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta, style: const TextStyle(color: kTextoSuave, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
        const SizedBox(height: 6),
        Text(valor, style: TextStyle(color: suave ? kTextoSuave : kTextoOscuro, fontSize: 15.5, height: 1.4)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final String nombre = (widget.profesional['usuarios']?['nombre'] ?? 'Profesional').toString();
    final String oficio = (widget.profesional['oficio'] ?? 'Sin especificar').toString();
    final String telefono = (widget.profesional['usuarios']?['telefono'] ?? 'N/A').toString();
    final String descripcion = (widget.profesional['descripcion'] ?? '').toString().trim();
    final String distancia = '${widget.profesional['distancia_km'] ?? '0.0'} km';
    final double? calificacion = (widget.profesional['calificacion_promedio'] as num?)?.toDouble();
    final int totalResenas = int.tryParse((widget.profesional['total_resenas'] ?? 0).toString()) ?? 0;
    final int completados = int.tryParse((widget.profesional['trabajos_completados'] ?? 0).toString()) ?? 0;
    final String? idProfesional = widget.profesional['id_profesional']?.toString();

    final partes = nombre.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    final String iniciales = partes.isEmpty ? '?' : (partes.length == 1 ? partes[0][0] : partes[0][0] + partes[1][0]).toUpperCase();

    final List<String> fotos = [];
    for (final campo in ['foto_1', 'foto_2', 'foto_3']) {
      final v = widget.profesional[campo];
      if (v != null && v.toString().trim().isNotEmpty) fotos.add(v.toString());
    }

    return Scaffold(
      backgroundColor: kCrema,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFEAE6DD)),
                        ),
                        child: const Icon(Icons.arrow_back, color: kTextoOscuro, size: 20),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'PROFESIONAL CERCA DE TI',
                      style: TextStyle(color: kTextoSuave, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.6),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Perfil profesional',
                      style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: kTextoOscuro, height: 1.1),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Conoce su experiencia y solicita su servicio cuando estés listo.',
                      style: TextStyle(color: kTextoSuave, fontSize: 15, height: 1.4),
                    ),
                    const SizedBox(height: 24),
                    // Tarjeta principal
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: const Color(0xFFEAE6DD)),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 14, offset: const Offset(0, 6))],
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: kVerde, borderRadius: BorderRadius.circular(26)),
                            child: Text(iniciales, style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            nombre,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: kTextoOscuro),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(20)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.handyman_outlined, size: 14, color: kEstadoVerde),
                                const SizedBox(width: 6),
                                Text(
                                  oficio.toUpperCase(),
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: kEstadoVerde, letterSpacing: 0.9),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _filaCalificacion(calificacion, totalResenas, completados),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.location_on_outlined, size: 18, color: kCoral),
                              const SizedBox(width: 6),
                              Text('A $distancia de ti', style: const TextStyle(fontSize: 13, color: kTextoSuave)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Información de contacto y descripción
                    _tarjetaSeccion(
                      titulo: 'Información de contacto',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _dato('TELÉFONO', telefono),
                          const SizedBox(height: 18),
                          _dato('ESPECIALIDAD', oficio),
                          const SizedBox(height: 18),
                          _dato('DISTANCIA', 'A $distancia de tu ubicación'),
                          const SizedBox(height: 18),
                          _dato(
                            'SOBRE SU TRABAJO',
                            descripcion.isNotEmpty ? descripcion : 'El profesional aún no ha añadido una descripción detallada.',
                            suave: descripcion.isEmpty,
                          ),
                        ],
                      ),
                    ),
                    // Portfolio
                    _tarjetaSeccion(
                      etiqueta: 'REFERENCIAS VISUALES',
                      titulo: 'Portfolio de trabajos',
                      child: fotos.isEmpty
                          ? const Text(
                              'Este profesional aún no ha registrado fotografías de sus trabajos.',
                              style: TextStyle(color: kTextoSuave, fontSize: 14, height: 1.4),
                            )
                          : LayoutBuilder(builder: (context, constraints) {
                              final lado = (constraints.maxWidth - 10) / 2;
                              return Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  for (final u in fotos)
                                    GestureDetector(
                                      onTap: () => _verFoto(u),
                                      child: SizedBox(
                                        width: lado,
                                        height: lado * 0.95,
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(18),
                                          child: Image.network(
                                            u,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => Container(
                                              color: const Color(0xFFEFEBE3),
                                              child: const Center(child: Icon(Icons.broken_image_outlined, color: kTextoSuave)),
                                            ),
                                            loadingBuilder: (context, child, progreso) => progreso == null
                                                ? child
                                                : Container(
                                                    color: const Color(0xFFEFEBE3),
                                                    child: const Center(
                                                      child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: kCoral)),
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }),
                    ),
                    // Reseñas de clientes
                    if (idProfesional != null) SeccionResenas(idProfesional: idProfesional, token: widget.token),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
              decoration: BoxDecoration(
                color: Colors.white,
                border: const Border(top: BorderSide(color: Color(0xFFEAE6DD))),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 12, offset: const Offset(0, -4))],
              ),
              child: _botonCoral('Solicitar servicio', false, () => _mostrarModalSolicitud(context)),
            ),
          ],
        ),
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
          // Mío: verde a la derecha. Del otro: blanco con borde a la izquierda.
          color: esMio ? kVerde : Colors.white,
          border: esMio ? null : Border.all(color: const Color(0xFFEAE6DD)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18.0),
            topRight: const Radius.circular(18.0),
            bottomLeft: esMio ? const Radius.circular(18.0) : const Radius.circular(4.0),
            bottomRight: esMio ? const Radius.circular(4.0) : const Radius.circular(18.0),
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 6, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: esMio ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              (msg['contenido'] ?? '').toString(),
              style: TextStyle(fontSize: 14.5, height: 1.35, color: esMio ? Colors.white : kTextoOscuro),
            ),
            if (hora.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                hora,
                style: TextStyle(fontSize: 10, color: esMio ? Colors.white70 : kTextoSuave),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String titulo = widget.titulo ?? 'Solicitud #${widget.idSolicitud}';
    final String inicial = titulo.isNotEmpty ? titulo[0].toUpperCase() : '?';

    return Scaffold(
      backgroundColor: kCrema,
      appBar: AppBar(
        backgroundColor: kCrema,
        foregroundColor: kTextoOscuro,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xFFDCEBE0), borderRadius: BorderRadius.circular(12)),
              child: Text(inicial, style: const TextStyle(color: kVerde, fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: kTextoOscuro)),
                  Text('Solicitud #${widget.idSolicitud}', style: const TextStyle(fontSize: 12, color: kTextoSuave)),
                ],
              ),
            ),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFEAE6DD)),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator(color: kCoral))
                : _mensajes.isEmpty
                    ? _estadoVacio(Icons.chat_bubble_outline, 'No hay mensajes aún.\n¡Escribe el primero!')
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16.0),
                        itemCount: _mensajes.length,
                        itemBuilder: (context, index) => _burbuja(_mensajes[index]),
                      ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFEAE6DD))),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _mensajeController,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(color: kTextoOscuro, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Escribe un mensaje...',
                        hintStyle: const TextStyle(color: kTextoSuave, fontSize: 14),
                        filled: true,
                        fillColor: kCrema,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: kVerde, width: 1.2)),
                      ),
                      onSubmitted: (_) => _enviarMensaje(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Material(
                    color: kCoral,
                    shape: const CircleBorder(),
                    elevation: 4,
                    shadowColor: kCoral.withOpacity(0.5),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _enviarMensaje,
                      child: const Padding(
                        padding: EdgeInsets.all(13),
                        child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      ),
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
