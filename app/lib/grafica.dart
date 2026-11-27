import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'lectura.dart';
import 'monitor.dart';
import 'tema.dart';

class GraficaSensor extends StatelessWidget {
  const GraficaSensor({
    super.key,
    required this.puntos,
    required this.valor,
    required this.limites,
    required this.ahora,
    this.ventana = Monitor.ventanaGrafica,
  });

  final List<Punto> puntos;
  final double? Function(Punto) valor;
  final Limites limites;
  final DateTime ahora;
  final Duration ventana;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 190),
      painter: _Pintor(puntos, valor, limites, ahora, ventana),
    );
  }
}

class _Pintor extends CustomPainter {
  _Pintor(this.puntos, this.valor, this.limites, this.ahora, this.ventana);

  final List<Punto> puntos;
  final double? Function(Punto) valor;
  final Limites limites;
  final DateTime ahora;
  final Duration ventana;

  static const _izq = 34.0, _der = 8.0, _arriba = 8.0, _abajo = 20.0;
  // Más de esto sin datos se dibuja como un corte en la línea
  static const _hueco = Duration(milliseconds: 3500);

  void _texto(Canvas canvas, String s, Offset pos, Color color, {bool derecha = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: 10, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, derecha ? pos - Offset(tp.width, tp.height / 2) : pos);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(_izq, _arriba, size.width - _der, size.height - _abajo);
    final inicio = ahora.subtract(ventana);
    final visibles = [
      for (final p in puntos)
        if (!p.hora.isBefore(inicio) && valor(p) != null && valor(p)!.isFinite) p,
    ];
    final valores = visibles.map((p) => valor(p)!);

    final maxDato = valores.isEmpty ? 0.0 : valores.reduce(max);
    final minDato = valores.isEmpty ? 0.0 : valores.reduce(min);
    final yMax = max(limites.rojo * 1.3, maxDato * 1.1);
    final yMin = min(0.0, minDato * 1.1);
    double y(double v) => area.bottom - (v - yMin) / (yMax - yMin) * area.height;
    double x(DateTime t) =>
        area.left + t.difference(inicio).inMilliseconds / ventana.inMilliseconds * area.width;

    canvas.save();
    canvas.clipRect(area);
    final franjas = [
      (yMin, limites.amarillo, Colores.verde.withValues(alpha: 0.07)),
      (limites.amarillo, limites.rojo, Colores.amarillo.withValues(alpha: 0.13)),
      (limites.rojo, yMax, Colores.rojo.withValues(alpha: 0.10)),
    ];
    for (final (desde, hasta, color) in franjas) {
      canvas.drawRect(
        Rect.fromLTRB(area.left, y(hasta), area.right, y(desde)),
        Paint()..color = color,
      );
    }
    canvas.restore();

    final guia = Paint()
      ..color = const Color(0xFFD5DCE1)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(area.left, y(0)), Offset(area.right, y(0)), guia);
    _texto(canvas, '0', Offset(area.left - 4, y(0)), Colores.textoSuave, derecha: true);

    for (final (v, color) in [(limites.amarillo, Colores.amarillo), (limites.rojo, Colores.rojo)]) {
      final py = y(v);
      final trazo = Paint()
        ..color = color
        ..strokeWidth = 1.2;
      for (var px = area.left; px < area.right; px += 8) {
        canvas.drawLine(Offset(px, py), Offset(min(px + 4, area.right), py), trazo);
      }
      _texto(canvas, _corto(v), Offset(area.left - 4, py), color, derecha: true);
    }

    for (var i = 0; i <= 3; i++) {
      final px = area.left + area.width * i / 3;
      canvas.drawLine(Offset(px, area.bottom), Offset(px, area.bottom + 3), guia);
      final etiqueta = i == 3 ? 'ahora' : '-${3 - i} min';
      final tp = TextPainter(
        text: TextSpan(text: etiqueta, style: const TextStyle(fontSize: 10, color: Colores.textoSuave)),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (px - tp.width / 2).clamp(area.left, area.right - tp.width);
      tp.paint(canvas, Offset(dx, area.bottom + 5));
    }

    if (visibles.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'Esperando datos…',
          style: TextStyle(fontSize: 13, color: Colores.textoSuave),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, area.center - Offset(tp.width / 2, tp.height / 2));
      return;
    }

    final linea = Path();
    DateTime? anterior;
    for (final p in visibles) {
      final o = Offset(x(p.hora), y(valor(p)!));
      if (anterior == null || p.hora.difference(anterior) > _hueco) {
        linea.moveTo(o.dx, o.dy);
      } else {
        linea.lineTo(o.dx, o.dy);
      }
      anterior = p.hora;
    }
    canvas.drawPath(
      linea,
      Paint()
        ..color = Colores.primario
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final ultimo = visibles.last;
    final pu = Offset(x(ultimo.hora), y(valor(ultimo)!));
    canvas.drawCircle(pu, 4.5, Paint()..color = Colors.white);
    canvas.drawCircle(pu, 3.2, Paint()..color = Colores.primario);
  }

  static String _corto(double v) =>
      v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  @override
  bool shouldRepaint(_Pintor old) => true;
}
