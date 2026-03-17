import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Returns null on success, or an error message on failure.
  static Future<String?> signIn(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Authentication failed';
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> signUp(String email, String password) async {
    try {
      await _auth.createUserWithEmailAndPassword(email: email, password: password);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Sign up failed';
    } catch (e) {
      return e.toString();
    }
  }

  static Future<void> signOut() => _auth.signOut();
}
