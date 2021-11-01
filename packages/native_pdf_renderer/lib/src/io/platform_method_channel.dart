import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:native_pdf_renderer/src/get_pixels/main.dart';
import 'package:native_pdf_renderer/src/interfaces/document.dart';
import 'package:native_pdf_renderer/src/interfaces/page.dart';
import 'package:native_pdf_renderer/src/interfaces/platform.dart';
import 'package:synchronized/synchronized.dart';
import 'package:universal_platform/universal_platform.dart';

const MethodChannel _channel = MethodChannel('io.scer.native_pdf_renderer');

final Lock _lock = Lock();

class PdfRenderPlatformMethodChannel extends PdfRenderPlatform {
  PdfDocument _open(Map<dynamic, dynamic> obj, String sourceName) =>
      PdfDocumentMethodChannel._(
        sourceName: sourceName,
        id: obj['id'] as String,
        pagesCount: obj['pagesCount'] as int,
      );

  /// Open PDF document from filesystem path
  @override
  Future<PdfDocument> openFile(String filePath) async {
    if (UniversalPlatform.isWeb) {
      throw PlatformNotSupportedException();
    }
    return _open(
      (await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'open.document.file',
        filePath,
      ))!,
      'file:$filePath',
    );
  }

  /// Open PDF document from application assets
  @override
  Future<PdfDocument> openAsset(String name) async => _open(
        (await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'open.document.asset',
          name,
        ))!,
        'asset:$name',
      );

  /// Open PDF file from memory (Uint8List)
  @override
  Future<PdfDocument> openData(Uint8List data) async => _open(
        (await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'open.document.data',
          data,
        ))!,
        'memory:binary',
      );
}

/// Handles PDF document loaded on memory.
class PdfDocumentMethodChannel extends PdfDocument {
  PdfDocumentMethodChannel._({
    required String sourceName,
    required String id,
    required int pagesCount,
  })  : _pages = List<PdfPage?>.filled(pagesCount, null),
        super(
          sourceName: sourceName,
          id: id,
          pagesCount: pagesCount,
        );

  final List<PdfPage?> _pages;

  @override
  Future<void> close() => _lock.synchronized(() async {
        if (isClosed) {
          throw PdfDocumentAlreadyClosedException();
        } else {
          isClosed = true;
        }
        return _channel.invokeMethod('close.document', id);
      });

  /// Get page object. The first page is 1.
  @override
  Future<PdfPage> getPage(int pageNumber) async {
    if (pageNumber < 1 || pageNumber > pagesCount) {
      throw RangeError.range(pageNumber, 1, pagesCount);
    }
    return _lock.synchronized<PdfPage>(() async {
      if (isClosed) {
        throw PdfDocumentAlreadyClosedException();
      }
      var page = _pages[pageNumber - 1];
      if (page == null) {
        final obj = (await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'open.page',
          {
            'documentId': id,
            'page': pageNumber,
          },
        ))!;

        page = PdfPageMethodChannel(
          document: this,
          id: obj['id'] as String,
          pageNumber: pageNumber,
          width: obj['width'] as int,
          height: obj['height'] as int,
        );
      }

      return page;
    });
  }

  @override
  bool operator ==(Object other) =>
      other is PdfDocumentMethodChannel && other.id == id;

  @override
  int get hashCode => identityHashCode(id);
}

class PdfPageMethodChannel extends PdfPage {
  PdfPageMethodChannel({
    required PdfDocument document,
    required String id,
    required int pageNumber,
    required int width,
    required int height,
  }) : super(
          document: document,
          id: id,
          pageNumber: pageNumber,
          width: width,
          height: height,
        );

  @override
  Future<PdfPageImage?> render({
    required int width,
    required int height,
    PdfPageFormat format = PdfPageFormat.PNG,
    String? backgroundColor,
    Rect? cropRect,
    int quality = 100,
    @visibleForTesting bool removeTempFile = true,
  }) =>
      _lock.synchronized<PdfPageImage?>(() async {
        if (document.isClosed) {
          throw PdfDocumentAlreadyClosedException();
        } else if (isClosed) {
          throw PdfPageAlreadyClosedException();
        }

        return PdfPageImageMethodChannel.render(
          pageId: id,
          pageNumber: pageNumber,
          width: width,
          height: height,
          format: format,
          backgroundColor: backgroundColor,
          crop: cropRect,
          quality: quality,
          removeTempFile: removeTempFile,
        );
      });

  @override
  Future<void> close() => _lock.synchronized(() async {
        if (isClosed) {
          throw PdfPageAlreadyClosedException();
        } else {
          isClosed = true;
        }
        return _channel.invokeMethod('close.page', id);
      });

  @override
  bool operator ==(Object other) =>
      other is PdfPageMethodChannel &&
      other.document.hashCode == document.hashCode &&
      other.pageNumber == pageNumber;

  @override
  int get hashCode => document.hashCode ^ pageNumber;
}

class PdfPageImageMethodChannel extends PdfPageImage {
  PdfPageImageMethodChannel({
    required String? id,
    required int pageNumber,
    required int? width,
    required int? height,
    required Uint8List bytes,
    required PdfPageFormat format,
    required int quality,
  }) : super(
          id: id,
          pageNumber: pageNumber,
          width: width,
          height: height,
          bytes: bytes,
          format: format,
          quality: quality,
        );

  /// Render a full image of specified PDF file.
  ///
  /// [width], [height] specify resolution to render in pixels.
  /// As default PNG uses transparent background. For change it you can set
  /// [backgroundColor] property like a hex string ('#000000')
  /// [format] - image type, all types can be seen here [PdfPageFormat]
  /// [crop] - render only the necessary part of the image
  /// [quality] - hint to the JPEG and WebP compression algorithms (0-100)
  static Future<PdfPageImage?> render({
    required String? pageId,
    required int pageNumber,
    required int width,
    required int height,
    required PdfPageFormat format,
    required String? backgroundColor,
    required Rect? crop,
    required int quality,
    required bool removeTempFile,
  }) async {
    if (format == PdfPageFormat.WEBP &&
        (UniversalPlatform.isIOS ||
            UniversalPlatform.isWindows ||
            UniversalPlatform.isMacOS)) {
      throw PdfNotSupportException(
        'PDF Renderer on IOS & Windows, MacOs platforms '
        'do not support WEBP format',
      );
    }

    backgroundColor ??=
        (format == PdfPageFormat.JPEG) ? '#FFFFFF' : '#00FFFFFF';

    final obj = await _channel.invokeMethod('render', {
      'pageId': pageId,
      'width': width,
      'height': height,
      'format': format.value,
      'backgroundColor': backgroundColor,
      'crop': crop != null,
      'crop_x': crop?.left.toInt(),
      'crop_y': crop?.top.toInt(),
      'crop_height': crop?.height.toInt(),
      'crop_width': crop?.width.toInt(),
      'quality': quality,
    });

    if (!(obj is Map<dynamic, dynamic>)) {
      return null;
    }

    final retWidth = obj['width'] as int?, retHeight = obj['height'] as int?;
    late final Uint8List pixels;
    if (UniversalPlatform.isAndroid ||
        UniversalPlatform.isIOS ||
        UniversalPlatform.isMacOS) {
      pixels = await getPixels(
        path: obj['path'],
        removeTempFile: removeTempFile,
      );
    } else {
      pixels = await getPixels(
        bytes: obj['data'],
        removeTempFile: removeTempFile,
      );
    }

    return PdfPageImageMethodChannel(
      id: pageId,
      pageNumber: pageNumber,
      width: retWidth,
      height: retHeight,
      bytes: pixels,
      format: format,
      quality: quality,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PdfPageImageMethodChannel &&
      other.bytes.lengthInBytes == bytes.lengthInBytes;

  @override
  int get hashCode => identityHashCode(id) ^ pageNumber;
}
