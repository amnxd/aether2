import 'package:flutter/material.dart';
import 'signup_screen.dart';
import '../services/backend_service.dart';
import 'home_page.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _rememberMe = false;
  bool _passwordVisible = false;

  String? _validateLogin(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'Please enter email or username';

    // If it looks like an email, validate email format.
    if (value.contains('@')) {
      final emailRegex = RegExp(r"^[^@\s]+@[^@\s]+\.[^@\s]+$");
      if (!emailRegex.hasMatch(value)) return 'Enter a valid email';
      return null;
    }

    // Otherwise validate username: 3-24 chars, letters/numbers/underscore.
    final u = value.toLowerCase();
    if (u.length < 3 || u.length > 24) return 'Username must be 3-24 characters';
    final usernameRegex = RegExp(r'^[a-z0-9_]+$');
    if (!usernameRegex.hasMatch(u)) return 'Username can only use letters, numbers, _';
    return null;
  }

  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Please enter password';
    if (v.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    await BackendService.warmUp();
    final err = await BackendService.login(
      _loginController.text.trim(),
      _passwordController.text,
      rememberMe: _rememberMe,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextFormField(
                controller: _loginController,
                decoration: const InputDecoration(labelText: 'Email or username'),
                keyboardType: TextInputType.emailAddress,
                validator: _validateLogin,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                obscureText: !_passwordVisible,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
                    icon: Icon(_passwordVisible ? Icons.visibility_off : Icons.visibility),
                  ),
                ),
                validator: _validatePassword,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _rememberMe,
                onChanged: _loading ? null : (v) => setState(() => _rememberMe = v ?? false),
                title: const Text('Remember me'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading ? const CircularProgressIndicator() : const Text('Login'),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Don't have an account?"),
                  TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignupScreen())), child: const Text('Sign up')),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}
