import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

const _authEndpoint = String.fromEnvironment('ZAKAT_AUTH_ENDPOINT');
const _notificationEndpoint = String.fromEnvironment(
  'ZAKAT_NOTIFICATION_ENDPOINT',
);

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoggingIn = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_authEndpoint.isEmpty) {
      _showMessage('لم يتم ضبط رابط خدمة تسجيل دخول الإدارة.');
      return;
    }

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      _showMessage('أدخل اسم المستخدم وكلمة المرور.');
      return;
    }

    setState(() => _isLoggingIn = true);

    try {
      final session = await _authenticateAdmin(
        username: username,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => AdminDashboardPage(session: session),
        ),
      );
    } catch (_) {
      _showMessage('بيانات الدخول غير صحيحة أو الخدمة غير متاحة.');
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  Future<AdminSession> _authenticateAdmin({
    required String username,
    required String password,
  }) async {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse(_authEndpoint))
          .timeout(const Duration(seconds: 12));

      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'username': username,
          'password': password,
          'source': 'zakat_radio_app',
        }),
      );

      final response = await request.close().timeout(
            const Duration(seconds: 12),
          );
      final responseBody = await utf8.decoder.bind(response).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Admin authentication failed');
      }

      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid auth response');
      }

      final token = decoded['token'];
      if (token is! String || token.isEmpty) {
        throw const FormatException('Missing auth token');
      }

      return AdminSession(token: token, username: username);
    } finally {
      client.close(force: true);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F292D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F292D),
          foregroundColor: Colors.white,
          title: const Text('دخول الإدارة'),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.admin_panel_settings_rounded,
                      color: Color(0xFFD5C09C),
                      size: 56,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'لوحة الإشعارات',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFD5C09C),
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'تسجيل الدخول يتم عبر خدمة آمنة خارج التطبيق.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.68),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 26),
                    _AdminTextField(
                      controller: _usernameController,
                      label: 'اسم المستخدم',
                      icon: Icons.person_rounded,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    _AdminTextField(
                      controller: _passwordController,
                      label: 'كلمة المرور',
                      icon: Icons.lock_rounded,
                      obscureText: _obscurePassword,
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                      ),
                      onSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _isLoggingIn ? null : _login,
                      icon: _isLoggingIn
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login_rounded),
                      label: Text(_isLoggingIn ? 'جار الدخول...' : 'دخول'),
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

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key, required this.session});

  final AdminSession session;

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _sendNotification() async {
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();

    if (title.isEmpty || body.isEmpty) {
      _showMessage('اكتب عنوان ونص الإشعار أولاً.');
      return;
    }

    if (_notificationEndpoint.isEmpty) {
      _showMessage('لم يتم ضبط رابط خدمة إرسال الإشعارات.');
      return;
    }

    setState(() => _isSending = true);

    try {
      await _postNotification(title: title, body: body);
      _titleController.clear();
      _bodyController.clear();
      _showMessage('تم إرسال طلب الإشعار بنجاح.');
    } catch (_) {
      _showMessage('تعذر إرسال الإشعار حالياً.');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _postNotification({
    required String title,
    required String body,
  }) async {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse(_notificationEndpoint))
          .timeout(const Duration(seconds: 12));

      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${widget.session.token}',
      );
      request.write(
        jsonEncode({
          'title': title,
          'body': body,
          'target': 'all',
          'source': 'zakat_radio_app',
        }),
      );

      final response = await request.close().timeout(
            const Duration(seconds: 12),
          );
      await response.drain<void>();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Notification endpoint failed');
      }
    } finally {
      client.close(force: true);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F292D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F292D),
          foregroundColor: Colors.white,
          title: const Text('داشبورد الإشعارات'),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.notifications_active_rounded,
                      color: Color(0xFFD5C09C),
                      size: 54,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'إرسال إشعار للمستخدمين',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFD5C09C),
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'مسجل باسم ${widget.session.username}. سيتم إرسال الطلب بتوكن آمن من الخادم.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.68),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _AdminTextField(
                      controller: _titleController,
                      label: 'عنوان الإشعار',
                      icon: Icons.title_rounded,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    _AdminTextField(
                      controller: _bodyController,
                      label: 'نص الإشعار',
                      icon: Icons.short_text_rounded,
                      minLines: 4,
                      maxLines: 6,
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _isSending ? null : _sendNotification,
                      icon: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded),
                      label: Text(_isSending ? 'جار الإرسال...' : 'إرسال'),
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

class AdminSession {
  const AdminSession({required this.token, required this.username});

  final String token;
  final String username;
}

class _AdminTextField extends StatelessWidget {
  const _AdminTextField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.suffixIcon,
    this.textInputAction,
    this.onSubmitted,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final Widget? suffixIcon;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      minLines: minLines,
      maxLines: obscureText ? 1 : maxLines,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.07),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: const Color(0xFFD5C09C).withValues(alpha: 0.28),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFFD5C09C), width: 1.4),
        ),
      ),
    );
  }
}
