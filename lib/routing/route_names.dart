/// Centralized route path constants
abstract class RouteNames {
  // Auth
  static const String splash = '/';
  static const String roleSelection = '/role-selection';
  static const String signIn = '/sign-in';
  static const String signUp = '/sign-up';
  static const String biometricEnrollment = '/biometric-enrollment';

  // Patient
  static const String patientDashboard = '/patient';
  static const String patientPrescriptions = '/patient/prescriptions';
  static const String patientMedicalHistory = '/patient/history';
  static const String patientQrCode = '/patient/qr-code';
  static const String patientProfile = '/patient/profile';
  static const String patientPrivacy = '/patient/privacy';

  // Doctor
  static const String doctorDashboard = '/doctor';
  static const String doctorPatientLookup = '/doctor/patient-lookup';
  static const String doctorNewPrescription = '/doctor/new-prescription';
  static const String doctorHistory = '/doctor/history';

  // Pharmacist
  static const String pharmacistDashboard = '/pharmacist';
  static const String pharmacistDispense = '/pharmacist/dispense';
  static const String pharmacistHistory = '/pharmacist/history';

  // First Responder
  static const String firstResponderDashboard = '/first-responder';
  static const String firstResponderScan = '/first-responder/scan';
  static const String firstResponderEmergencyView = '/first-responder/emergency';
}

