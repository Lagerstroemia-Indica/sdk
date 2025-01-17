// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/protocol/protocol.dart';
import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:analysis_server/src/handler/legacy/legacy_handler.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:dart_style/src/dart_formatter.dart';
import 'package:dart_style/src/exceptions.dart';
import 'package:dart_style/src/source_code.dart';
import 'package:pub_semver/pub_semver.dart';

/// The handler for the `edit.format` request.
class EditFormatHandler extends LegacyHandler {
  /// Initialize a newly created handler to be able to service requests for the
  /// [server].
  EditFormatHandler(
      super.server, super.request, super.cancellationToken, super.performance);

  @override
  Future<void> handle() async {
    var params = EditFormatParams.fromRequest(request,
        clientUriConverter: server.uriConverter);
    var file = params.file;

    String unformattedCode;
    try {
      var resource = server.resourceProvider.getFile(file);
      unformattedCode = resource.readAsStringSync();
    } catch (e) {
      sendResponse(Response.formatInvalidFile(request));
      return;
    }

    int? start = params.selectionOffset;
    int? length = params.selectionLength;

    // No need to preserve 0,0 selection
    if (start == 0 && length == 0) {
      start = null;
      length = null;
    }

    var code = SourceCode(
      unformattedCode,
      selectionStart: start,
      selectionLength: length,
    );

    var driver = server.getAnalysisDriver(file);
    var unit = await driver?.getResolvedUnit(file);

    int? pageWidth;
    Version effectiveLanguageVersion;
    if (unit is ResolvedUnitResult) {
      pageWidth = unit.analysisOptions.formatterOptions.pageWidth;
      effectiveLanguageVersion = unit.libraryElement2.effectiveLanguageVersion;
    } else {
      // If the unit doesn't resolve, don't try to format it since we don't
      // know what language version (and thus what formatting style) to apply.
      sendResponse(Response.formatWithErrors(request));
      return;
    }

    var formatter = DartFormatter(
        pageWidth: pageWidth ?? params.lineLength,
        languageVersion: effectiveLanguageVersion);
    SourceCode formattedResult;
    try {
      formattedResult = formatter.formatSource(code);
    } on FormatterException {
      sendResponse(Response.formatWithErrors(request));
      return;
    }
    var formattedSource = formattedResult.text;

    var edits = <SourceEdit>[];

    if (formattedSource != unformattedCode) {
      // TODO(brianwilkerson): replace full replacements with smaller, more targeted edits
      var edit = SourceEdit(0, unformattedCode.length, formattedSource);
      edits.add(edit);
    }

    var newStart = formattedResult.selectionStart;
    var newLength = formattedResult.selectionLength;

    // Sending null start/length values would violate protocol, so convert back
    // to 0.
    newStart ??= 0;
    newLength ??= 0;

    sendResult(EditFormatResult(edits, newStart, newLength));
  }
}
