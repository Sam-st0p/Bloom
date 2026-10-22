// lib/utils/error_handler.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppErrors {
  AppErrors._();

  static const String offlineMessage = 'Unable to connect. Check your internet.';
  static const String genericMessage = 'Something went wrong. Please try again.';

  static bool isNetworkError(Object e) {
    if (e is SocketException || e is TimeoutException) return true;
    final text = e.toString();
    return text.contains('ClientException') ||
        text.contains('AuthRetryableFetchException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Network is unreachable');
  }

  /// Shows a snackbar with the right message. Never throws.
  static void show(BuildContext context, Object error) {
    if (!context.mounted) return;
    final message = isNetworkError(error) ? offlineMessage : genericMessage;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: GoogleFonts.nunito(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          backgroundColor: const Color(0xFFC62828),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}