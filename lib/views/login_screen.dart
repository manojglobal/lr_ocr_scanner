import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/gemini_backend_service.dart';
import '../state/batch_controller.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  final BatchProcessingController controller;

  const LoginScreen({super.key, required this.controller});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _nameController = TextEditingController(text: 'Ruchita Patel');
  final TextEditingController _mobileController = TextEditingController(text: '9876543210');
  final List<TextEditingController> _otpControllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes = List.generate(6, (_) => FocusNode());

  bool _isOtpSent = false;
  bool _isLoading = false;
  String? _errorMessage;

  /// Temporary configuration: set to false to re-enable 6-digit OTP verification.
  static const bool hideOtpSection = true;

  Timer? _countdownTimer;
  int _cooldownSeconds = 30;

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  Future<void> _checkExistingSession() async {
    final prefs = await SharedPreferences.getInstance();
    final mobile = prefs.getString('bnf_user_mobile');
    final name = prefs.getString('bnf_user_name') ?? 'Logistics User';
    final token = prefs.getString('bnf_user_token');
    if (mobile != null && mobile.isNotEmpty && token != null && token.isNotEmpty) {
      widget.controller.setActiveUser(mobile, name: name, sessionToken: token);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => HomeScreen(controller: widget.controller)),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mobileController.dispose();
    for (final c in _otpControllers) {
      c.dispose();
    }
    for (final f in _otpFocusNodes) {
      f.dispose();
    }
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startTimer(int seconds) {
    _countdownTimer?.cancel();
    setState(() {
      _cooldownSeconds = seconds;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_cooldownSeconds <= 1) {
        t.cancel();
        setState(() {
          _cooldownSeconds = 0;
        });
      } else {
        setState(() {
          _cooldownSeconds--;
        });
      }
    });
  }

  /// Simplified direct authentication handler (OTP section hidden temporarily)
  Future<void> _handleDirectLogin() async {
    var mobile = _mobileController.text.replaceAll(RegExp(r'\D'), '');
    if (mobile.startsWith('91') && mobile.length == 12) mobile = mobile.substring(2);
    if (mobile.startsWith('0') && mobile.length == 11) mobile = mobile.substring(1);
    final name = _nameController.text.trim();

    if (mobile.length != 10 || !RegExp(r'^[5-9]').hasMatch(mobile)) {
      setState(() => _errorMessage = 'Please enter a valid 10-digit Indian mobile number.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await widget.controller.geminiService.directLogin(mobile, name: name);

    setState(() => _isLoading = false);

    if (res['success'] == true) {
      final token = res['token']?.toString();
      final userName = name.isNotEmpty ? name : 'Logistics User';
      widget.controller.setActiveUser(
        mobile,
        name: userName,
        sessionToken: token,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bnf_user_name', userName);
      await prefs.setString('bnf_user_mobile', mobile);
      if (token != null) {
        await prefs.setString('bnf_user_token', token);
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => HomeScreen(controller: widget.controller)),
        );
      }
    } else {
      setState(() => _errorMessage = res['error']?.toString() ?? 'Login failed. Please try again.');
    }
  }

  void _showServerConfigDialog() {
    final textController = TextEditingController(text: widget.controller.geminiService.serverUrl);
    bool isPinging = false;
    String? pingResult;
    bool? isOnline;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.hub_outlined, color: Colors.indigo),
              SizedBox(width: 8),
              Text('Server IP Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Set the local IP of your computer running main.py:',
                  style: TextStyle(fontSize: 12, color: Colors.black87),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: textController,
                  decoration: InputDecoration(
                    labelText: 'Server Base URL',
                    hintText: 'http://192.168.1.2:8000',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.restart_alt, size: 18),
                      tooltip: 'Reset to default IP',
                      onPressed: () {
                        textController.text = GeminiBackendService.defaultServerUrl;
                        setDialogState(() {});
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('PC IP (192.168.1.2:8000)', style: TextStyle(fontSize: 11)),
                      onPressed: () {
                        textController.text = 'http://192.168.1.2:8000';
                        setDialogState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: isPinging
                          ? null
                          : () async {
                              setDialogState(() {
                                isPinging = true;
                                pingResult = null;
                                isOnline = null;
                              });
                              await widget.controller.geminiService.updateServerUrl(textController.text);
                              final ok = await widget.controller.geminiService.checkHealth();
                              setDialogState(() {
                                isPinging = false;
                                isOnline = ok;
                                pingResult = ok ? 'Connected! (Server Online)' : 'Cannot reach server. Check Wi-Fi & IP.';
                              });
                            },
                      icon: isPinging
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_tethering, size: 16),
                      label: const Text('Test Connection'),
                    ),
                    const SizedBox(width: 8),
                    if (pingResult != null)
                      Expanded(
                        child: Text(
                          pingResult!,
                          style: TextStyle(
                            fontSize: 11,
                            color: isOnline == true ? Colors.green.shade700 : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await widget.controller.geminiService.updateServerUrl(textController.text);
                setState(() {});
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Save & Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSendOtp() async {
    final mobile = _mobileController.text.trim();
    final name = _nameController.text.trim();

    if (mobile.length != 10) {
      setState(() => _errorMessage = 'Please enter a valid 10-digit mobile number.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await widget.controller.geminiService.sendOtp(mobile, name: name);

    setState(() => _isLoading = false);

    if (res['success'] == true) {
      setState(() {
        _isOtpSent = true;
      });
      _startTimer(res['resend_cooldown'] as int? ?? 30);

      // Auto-fill dev_otp if provided
      if (res['dev_otp'] != null) {
        final devOtp = res['dev_otp'].toString();
        for (int i = 0; i < devOtp.length && i < 6; i++) {
          _otpControllers[i].text = devOtp[i];
        }
      }
    } else {
      setState(() => _errorMessage = res['error']?.toString() ?? 'Failed to send OTP');
    }
  }

  Future<void> _handleVerifyOtp() async {
    final mobile = _mobileController.text.trim();
    final name = _nameController.text.trim();
    final otp = _otpControllers.map((c) => c.text).join();

    if (otp.length != 6) {
      setState(() => _errorMessage = 'Please enter all 6 digits of the OTP.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await widget.controller.geminiService.verifyOtp(mobile, otp, name: name);

    setState(() => _isLoading = false);

    if (res['success'] == true) {
      final token = res['token']?.toString();
      widget.controller.setActiveUser(
        mobile,
        name: name.isNotEmpty ? name : 'Logistics User',
        sessionToken: token,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bnf_user_name', name.isNotEmpty ? name : 'Logistics User');
      await prefs.setString('bnf_user_mobile', mobile);
      if (token != null) {
        await prefs.setString('bnf_user_token', token);
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => HomeScreen(controller: widget.controller)),
        );
      }
    } else {
      setState(() => _errorMessage = res['error']?.toString() ?? 'Invalid OTP code');
    }
  }

  Widget _buildErrorMessage() {
    if (_errorMessage == null) return const SizedBox.shrink();
    final isConnectionErr = _errorMessage!.toLowerCase().contains('connect') ||
        _errorMessage!.toLowerCase().contains('socket') ||
        _errorMessage!.toLowerCase().contains('failed host') ||
        _errorMessage!.toLowerCase().contains('timed out');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, size: 16, color: Colors.red),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Connection Notice',
                  style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_errorMessage!, style: const TextStyle(color: Colors.red, fontSize: 11)),
          if (isConnectionErr) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: _showServerConfigDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.settings_ethernet, size: 13, color: Colors.red),
                    SizedBox(width: 4),
                    Text(
                      'Configure Server IP (Tap here)',
                      style: TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const brandNavy = Color(0xFF0F172A);
    const brandBlue = Color(0xFF0284C7);
    const brandOrange = Color(0xFFEA580C);

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header Fleet Banner
                    Container(
                      width: double.infinity,
                      color: brandNavy,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withAlpha(40),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.shield, size: 12, color: Colors.cyanAccent),
                                    SizedBox(width: 4),
                                    Text(
                                      'Secure Logistics Portal',
                                      style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.settings_ethernet, color: Colors.white70, size: 22),
                                tooltip: 'Server IP Settings',
                                onPressed: _showServerConfigDialog,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'BOX N FREIGHT',
                            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Fast Consignment Processing & Excel Automation',
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),

                    // Body Input Section
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            hideOtpSection ? 'Sign In to Logistics Portal' : 'Login with Mobile & OTP',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: brandNavy),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            hideOtpSection
                                ? 'Enter your mobile number to securely sign in and access LR processing.'
                                : 'Complete mobile verification to unlock LR upload option.',
                            style: const TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                          const SizedBox(height: 20),

                          if (hideOtpSection) ...[
                            // Simplified Direct Login (OTP section hidden temporarily)
                            TextField(
                              controller: _nameController,
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) => _handleDirectLogin(),
                              decoration: const InputDecoration(
                                labelText: 'Your Name (Optional)',
                                prefixIcon: Icon(Icons.person_outline, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _mobileController,
                              keyboardType: TextInputType.phone,
                              textInputAction: TextInputAction.done,
                              maxLength: 10,
                              onSubmitted: (_) => _handleDirectLogin(),
                              decoration: const InputDecoration(
                                labelText: 'Mobile Number *',
                                prefixText: '+91 ',
                                counterText: '',
                                prefixIcon: Icon(Icons.phone_android, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildErrorMessage(),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _handleDirectLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: brandBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: _isLoading
                                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text('Login & Continue', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            ),
                          ] else if (!_isOtpSent) ...[
                            // Step 1: Name & Mobile
                            TextField(
                              controller: _nameController,
                              decoration: const InputDecoration(
                                labelText: 'Your Name',
                                prefixIcon: Icon(Icons.person_outline, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _mobileController,
                              keyboardType: TextInputType.phone,
                              maxLength: 10,
                              decoration: const InputDecoration(
                                labelText: 'Mobile Number *',
                                prefixText: '+91 ',
                                counterText: '',
                                prefixIcon: Icon(Icons.phone_android, size: 20),
                                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildErrorMessage(),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _handleSendOtp,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: brandOrange,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: _isLoading
                                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text('Send OTP', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            ),
                          ] else ...[
                            // Step 2: OTP Verification
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('OTP sent to +91 ${_mobileController.text}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                TextButton(
                                   onPressed: () => setState(() => _isOtpSent = false),
                                  child: const Text('Change', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: List.generate(6, (index) {
                                return SizedBox(
                                  width: 44,
                                  height: 52,
                                  child: TextField(
                                    controller: _otpControllers[index],
                                    focusNode: _otpFocusNodes[index],
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    maxLength: 1,
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                    decoration: const InputDecoration(
                                      counterText: '',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                                    ),
                                    onChanged: (val) {
                                      if (val.isNotEmpty && index < 5) {
                                        _otpFocusNodes[index + 1].requestFocus();
                                      } else if (val.isEmpty && index > 0) {
                                        _otpFocusNodes[index - 1].requestFocus();
                                      }
                                    },
                                  ),
                                );
                              }),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _cooldownSeconds > 0 ? 'Resend in ${_cooldownSeconds}s' : 'OTP expired',
                                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                                ),
                                TextButton(
                                  onPressed: _cooldownSeconds == 0 ? _handleSendOtp : null,
                                  child: const Text('Resend OTP', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _buildErrorMessage(),
                            ElevatedButton(
                              onPressed: _isLoading ? null : _handleVerifyOtp,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: brandBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: _isLoading
                                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text('Verify & Continue', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            ),
                          ],

                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 12),

                          // Server connection status pill
                          Center(
                            child: InkWell(
                              onTap: _showServerConfigDialog,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.dns_outlined, size: 14, color: Colors.blueGrey),
                                    const SizedBox(width: 6),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 220),
                                      child: Text(
                                        'Server: ${widget.controller.geminiService.serverUrl}',
                                        style: const TextStyle(fontSize: 11, color: Colors.blueGrey, fontWeight: FontWeight.w500),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.edit, size: 12, color: Colors.blueGrey),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
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
