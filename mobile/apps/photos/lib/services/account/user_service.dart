import 'dart:async';
import "dart:io";

import 'package:dio/dio.dart';
import "package:ente_base/models/accounts.dart";
import 'package:ente_crypto/ente_crypto.dart';
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/foundation.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/signed_in_event.dart';
import 'package:photos/events/user_details_changed_event.dart';
import 'package:photos/events/user_logged_out_event.dart';
import 'package:photos/gateways/users/models/key_attributes.dart';
import 'package:photos/gateways/users/models/sessions.dart';
import 'package:photos/gateways/users/models/set_recovery_key_request.dart';
import "package:photos/gateways/users/users_gateway.dart";
import 'package:photos/models/user_details.dart';
import "package:photos/service_locator.dart";
import 'package:photos/src/rust/third_party/ente_frb_lib/accounts.dart'
    as accounts;
import "package:photos/ui/components/alert_bottom_sheet.dart";
import 'package:photos/ui/notification/toast.dart';
import 'package:photos/utils/dialog_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import "package:uuid/uuid.dart";

class UserService {
  static const keyHasEnabledTwoFactor = "has_enabled_two_factor";
  static const keyUserDetails = "user_details";
  static const kReferralSource = "referral_source";
  static const kIsEmailMFAEnabled = "is_email_mfa_enabled";
  static const _publicKeyBatchSize = 10;

  final _publicKeyCache = TimedCache<String, String>(
    duration: const Duration(seconds: 10),
  );

  final _logger = Logger((UserService).toString());
  final _config = Configuration.instance;
  late SharedPreferences _preferences;
  AccountsClient? _accountsClient;
  String? _accountsClientOrigin;
  StreamSubscription<UserLoggedOutEvent>? _loggedOutEventSubscription;
  StreamSubscription<SignedInEvent>? _signedInEventSubscription;

  UsersGateway get _gateway => usersGateway;

  final ValueNotifier<String?> emailValueNotifier = ValueNotifier<String?>(
    null,
  );

  UserService._privateConstructor();

  static final UserService instance = UserService._privateConstructor();

  Future<void> init() async {
    emailValueNotifier.value = Configuration.instance.getEmail();
    if (_loggedOutEventSubscription != null) {
      await _loggedOutEventSubscription!.cancel();
    }
    _loggedOutEventSubscription = Bus.instance.on<UserLoggedOutEvent>().listen((
      _,
    ) {
      _accountsClient = null;
      emailValueNotifier.value = null;
    });
    if (_signedInEventSubscription != null) {
      await _signedInEventSubscription!.cancel();
    }
    _signedInEventSubscription = Bus.instance.on<SignedInEvent>().listen((_) {
      emailValueNotifier.value = Configuration.instance.getEmail();
    });
    _preferences = await SharedPreferences.getInstance();
  }

  Future<void> sendFeedback(
    BuildContext context,
    String feedback, {
    String type = "SubCancellation",
  }) async {
    await _gateway.sendFeedback(feedback: feedback, type: type);
  }

  Future<String?> getPublicKey(String email) async {
    email = email.trim().toLowerCase();
    final String? cachedPubKey = _publicKeyCache.get(email);
    if (cachedPubKey != null) {
      return cachedPubKey;
    }
    final publicKey = await _gateway.getPublicKey(email);
    if (publicKey != null) {
      _publicKeyCache.set(email, publicKey);
    }
    return publicKey;
  }

  Future<Map<String, String?>> getPublicKeys(Iterable<String> emails) async {
    final normalizedEmails = <String>[];
    final seen = <String>{};
    for (final email in emails) {
      final normalizedEmail = email.trim().toLowerCase();
      if (normalizedEmail.isNotEmpty && seen.add(normalizedEmail)) {
        normalizedEmails.add(normalizedEmail);
      }
    }

    final result = <String, String?>{};
    final uncached = <String>[];
    for (final email in normalizedEmails) {
      final publicKey = _publicKeyCache.get(email);
      if (publicKey == null) {
        uncached.add(email);
      } else {
        result[email] = publicKey;
      }
    }

    for (final batch in uncached.chunks(_publicKeyBatchSize)) {
      final publicKeys = await _getPublicKeyBatch(batch);
      for (var index = 0; index < batch.length; index++) {
        final publicKey = publicKeys[index];
        result[batch[index]] = publicKey;
        if (publicKey != null && publicKey.isNotEmpty) {
          _publicKeyCache.set(batch[index], publicKey);
        }
      }
    }
    return result;
  }

  Future<List<String?>> _getPublicKeyBatch(List<String> emails) async {
    try {
      return await _gateway.getPublicKeys(emails);
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) {
        rethrow;
      }
    }

    final publicKeys = <String?>[];
    for (final email in emails) {
      publicKeys.add(await _gateway.getPublicKey(email));
    }
    return publicKeys;
  }

  UserDetails? getCachedUserDetails() {
    if (_preferences.containsKey(keyUserDetails)) {
      return UserDetails.fromJson(_preferences.getString(keyUserDetails)!);
    }
    return null;
  }

  Future<UserDetails> getUserDetailsV2({
    bool memoryCount = true,
    bool shouldCache = true,
  }) async {
    _logger.info("Fetching user details");
    final bool previousEmailMFAStatus = hasEmailMFAEnabled();
    final previousTwoFactorStatus = hasEnabledTwoFactor();
    final userDetails = await _gateway.getUserDetails(memoryCount: memoryCount);
    if (shouldCache) {
      await _preferences.setString(keyUserDetails, userDetails.toJson());
      bool hasSecurityStatusChanged = false;
      final profileData = userDetails.profileData;
      if (profileData != null) {
        final bool currentEmailMFAStatus = profileData.isEmailMFAEnabled;
        await _preferences.setBool(kIsEmailMFAEnabled, currentEmailMFAStatus);
        hasSecurityStatusChanged =
            hasSecurityStatusChanged ||
            previousEmailMFAStatus != currentEmailMFAStatus;
        final currentTwoFactorStatus = profileData.isTwoFactorEnabled;
        if (currentTwoFactorStatus != null) {
          await _setTwoFactor(currentTwoFactorStatus);
          hasSecurityStatusChanged =
              hasSecurityStatusChanged ||
              previousTwoFactorStatus != currentTwoFactorStatus;
        }
      }
      if (hasSecurityStatusChanged) {
        Bus.instance.fire(UserDetailsChangedEvent());
      }
      if (userDetails.email != _config.getEmail()) {
        await setEmail(userDetails.email);
      }
    }
    return userDetails;
  }

  Future<Sessions> getActiveSessions() async {
    return _gateway.getActiveSessions();
  }

  Future<void> terminateSession(String token) async {
    await _gateway.terminateSession(token);
  }

  Future<void> leaveFamilyPlan() async {
    try {
      await _gateway.leaveFamilyPlan();
    } on DioException catch (e) {
      _logger.warning('failed to leave family plan', e);
      rethrow;
    }
  }

  Future<void> logout(BuildContext context) async {
    try {
      await _gateway.logout();
      await Configuration.instance.logout();
      if (!context.mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      final bool silentlyIgnoreError =
          (e is DioException && e.response?.statusCode == 401) ||
          !endpointConfig.isProduction;

      if (silentlyIgnoreError) {
        if (!endpointConfig.isProduction) {
          _logger.info(
            "Custom endpoint detected, proceeding with local logout despite server error",
          );
        } else {
          _logger.info("Token already invalid, proceeding with local logout");
        }

        await Configuration.instance.logout();

        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        return;
      }

      _logger.severe("Failed to logout", e);
      // Let the logout dialog close before showing the error.
      if (!context.mounted) return;
      unawaited(
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!context.mounted) return;
          showGenericErrorBottomSheet(context: context, error: null);
        }),
      );
    }
  }

  Future<Map<String, dynamic>?> getTokenForPasskeySession(
    String sessionID,
  ) async {
    final response = await _withAccountsClient(
      (client) => client.pollPasskey(sessionId: sessionID),
    );
    return response?.toMap();
  }

  Future<void> setEmail(String email) async {
    await _config.setEmail(email);
    emailValueNotifier.value = email;
  }

  Future<void> setRefSource(String refSource) async {
    await _preferences.setString(kReferralSource, refSource);
  }

  Future<void> changeEmail(
    BuildContext context,
    String email,
    String ott,
  ) async {
    final dialog = createProgressDialog(context, context.strings.pleaseWait);
    await dialog.show();
    try {
      await _gateway.changeEmail(email: email, ott: ott);
      await setEmail(email);
      await dialog.hide();
      if (context.mounted) {
        showShortToast(
          context,
          context.strings.emailChangedTo(newEmail: email),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      Bus.instance.fire(UserDetailsChangedEvent());
    } on DioException catch (e) {
      await dialog.hide();
      if (e.response != null && e.response!.statusCode == 403) {
        if (!context.mounted) return;
        await showAlertBottomSheet(
          context,
          title: context.strings.oops,
          message: context.strings.thisEmailIsAlreadyInUse,
          assetPath: 'assets/warning-grey.png',
        );
      } else {
        if (!context.mounted) return;
        await showAlertBottomSheet(
          context,
          title: context.strings.incorrectCode,
          message: context.strings.authenticationFailedPleaseTryAgain,
          assetPath: 'assets/warning-grey.png',
        );
      }
    } catch (e) {
      await dialog.hide();
      _logger.warning(e);
      if (!context.mounted) return;
      await showAlertBottomSheet(
        context,
        title: context.strings.oops,
        message: context.strings.verificationFailedPleaseTryAgain,
        assetPath: 'assets/warning-grey.png',
      );
    }
  }

  Future<SignupKeys> generateKey(String password) {
    return _withAccountsClient(
      (client) => client.generateSignupKeys(
        password: password,
        srpUserId: const Uuid().v4(),
      ),
    );
  }

  Future<void> setAttributes(SignupKeys result) async {
    await _withAccountsClient(
      (client) => client.completeSignup(
        email: _config.getEmail()!,
        token: _config.getToken()!,
        keyAttributes: result.keyAttributes,
        srp: result.srp,
      ),
    );
    await _config.setKey(result.masterKey);
    await _config.setSecretKey(result.secretKey);
    await _config.setKeyAttributes(
      KeyAttributes.fromMap(result.keyAttributes.toMap()),
    );
  }

  Future<SrpAttributes> getSrpAttributes(String email) {
    return _withAccountsClient(
      (client) => client.getSrpAttributes(email: email),
    );
  }

  Future<Uint8List> unlockAccount(
    String password,
    KeyAttributes attributes, {
    Uint8List? keyEncryptionKey,
  }) async {
    final result = await _withAccountsClient(
      (client) => client.unlock(
        response: AuthResponse(
          id: _config.getUserID()!,
          keyAttributes: accountsKeyAttributes(attributes.toMap()),
          encryptedToken: _config.getEncryptedToken(),
          token: _config.getEncryptedToken() == null
              ? _config.getToken()
              : null,
        ),
        password: password,
        keyEncryptionKey: keyEncryptionKey,
      ),
    );
    await _config.setKey(result.masterKey);
    await _config.setSecretKey(result.secretKey);
    await _config.setToken(result.token);
    return result.loginKey;
  }

  Future<void> setupSrp(Uint8List loginKey) => _withAccountsClient(
    (client) => client.setupSrp(
      token: _config.getToken()!,
      srpUserId: const Uuid().v4(),
      loginKey: loginKey,
    ),
  );

  Future<void> changePassword(
    String password, {
    required bool logoutOtherDevices,
  }) async {
    final attributes = await _withAccountsClient(
      (client) => client.changePassword(
        token: _config.getToken()!,
        password: password,
        masterKey: _config.getKey()!,
        keyAttributes: accountsKeyAttributes(
          _config.getKeyAttributes()!.toMap(),
        ),
        logOutOtherDevices: logoutOtherDevices,
      ),
    );
    await _config.setKeyAttributes(KeyAttributes.fromMap(attributes.toMap()));
  }

  Future<void> recoverAccount(String recoveryKey) async {
    final result = await _withAccountsClient(
      (client) => client.recoverAccount(
        response: AuthResponse(
          id: _config.getUserID()!,
          keyAttributes: accountsKeyAttributes(
            _config.getKeyAttributes()!.toMap(),
          ),
          encryptedToken: _config.getEncryptedToken(),
          token: _config.getEncryptedToken() == null
              ? _config.getToken()
              : null,
        ),
        recoveryKey: recoveryKey,
      ),
    );
    await _config.setKey(result.masterKey);
    await _config.setSecretKey(result.secretKey);
    await _config.setToken(result.token);
  }

  Future<String> passkeyManagementUrl() => _withAccountsClient(
    (client) => client.passkeyManagementUrl(
      token: _config.getToken()!,
      recoveryKey: CryptoUtil.bin2hex(_config.getRecoveryKey()),
    ),
  );

  Future<void> setRecoveryKey(KeyAttributes keyAttributes) async {
    try {
      final setRecoveryKeyRequest = SetRecoveryKeyRequest(
        keyAttributes.masterKeyEncryptedWithRecoveryKey!,
        keyAttributes.masterKeyDecryptionNonce!,
        keyAttributes.recoveryKeyEncryptedWithMasterKey!,
        keyAttributes.recoveryKeyDecryptionNonce!,
      );
      await _gateway.setRecoveryKey(setRecoveryKeyRequest);
      await _config.setKeyAttributes(keyAttributes);
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<T> _withAccountsClient<T>(
    Future<T> Function(AccountsClient client) request,
  ) async {
    final client = _getAccountsClient();
    final email = _config.getEmail();
    final result = await request(client);
    if (client != _getAccountsClient() || email != _config.getEmail()) {
      throw const AccountsError.sessionExpired();
    }
    return result;
  }

  AccountsClient _getAccountsClient() {
    final origin = endpointConfig.endpoint;
    if (_accountsClient == null || _accountsClientOrigin != origin) {
      final services = ServiceLocator.instance;
      final client = accounts.createAccountsClient(
        config: AccountsClientConfig(
          origin: origin,
          clientPackage: services.packageInfo.packageName,
          clientVersion: services.packageInfo.version,
          userAgent:
              services.enteDio.options.headers[HttpHeaders.userAgentHeader]
                  as String,
        ),
      );
      _accountsClient = client;
      _accountsClientOrigin = origin;
    }
    return _accountsClient!;
  }

  Future<bool> enableTwoFactor(
    BuildContext context,
    String secret,
    String code,
  ) async {
    Uint8List recoveryKey;
    try {
      recoveryKey = await getOrCreateRecoveryKey(context);
    } catch (e) {
      if (!context.mounted) return false;
      await showGenericErrorBottomSheet(context: context, error: e);
      return false;
    }
    if (!context.mounted) return false;
    final dialog = createProgressDialog(context, context.strings.verifying);
    await dialog.show();
    try {
      await _withAccountsClient(
        (client) => client.enableTwoFactor(
          token: _config.getToken()!,
          secret: secret,
          recoveryKey: CryptoUtil.bin2hex(recoveryKey),
          code: code,
        ),
      );
      await _setTwoFactor(true);
      await dialog.hide();
      if (context.mounted) {
        Navigator.pop(context);
      }
      Bus.instance.fire(UserDetailsChangedEvent());
      return true;
    } catch (e, s) {
      await dialog.hide();
      _logger.severe("Failed to enable 2FA", e, s);
      if (e is AccountsError_IncorrectTotp) {
        if (!context.mounted) return false;
        showAlertBottomSheet(
          context,
          title: context.strings.incorrectCode,
          message: context.strings.pleaseVerifyTheCodeYouHaveEntered,
          assetPath: 'assets/warning-grey.png',
        ).ignore();
        return false;
      }
      if (!context.mounted) return false;
      // ignore: unawaited_futures
      showAlertBottomSheet(
        context,
        title: context.strings.somethingWentWrong,
        message: context.strings.pleaseContactSupportIfTheProblemPersists,
        assetPath: 'assets/warning-grey.png',
      );
    }
    return false;
  }

  Future<void> disableTwoFactor(BuildContext context) async {
    final dialog = createProgressDialog(
      context,
      context.strings.disablingTwofactorAuthentication,
    );
    await dialog.show();
    try {
      await _gateway.disableTwoFactor();
      await _setTwoFactor(false);
      await dialog.hide();
      Bus.instance.fire(UserDetailsChangedEvent());
      if (!context.mounted) return;
      showShortToast(
        context,
        context.strings.twofactorAuthenticationHasBeenDisabled,
      );
    } catch (e) {
      await dialog.hide();
      _logger.severe("Failed to disabled 2FA", e);
      if (!context.mounted) return;
      await showAlertBottomSheet(
        context,
        title: context.strings.somethingWentWrong,
        message: context.strings.pleaseContactSupportIfTheProblemPersists,
        assetPath: 'assets/warning-grey.png',
      );
    }
  }

  Future<Uint8List> getOrCreateRecoveryKey(BuildContext context) async {
    final String? encryptedRecoveryKey = _config
        .getKeyAttributes()!
        .recoveryKeyEncryptedWithMasterKey;
    if (encryptedRecoveryKey == null || encryptedRecoveryKey.isEmpty) {
      final dialog = createProgressDialog(context, context.strings.pleaseWait);
      await dialog.show();
      try {
        final keyAttributes = await _config.createNewRecoveryKey();
        await setRecoveryKey(keyAttributes);
        await dialog.hide();
      } catch (e, s) {
        await dialog.hide();
        _logger.severe("Failed to create recovery key", e, s);
        rethrow;
      }
    }
    final recoveryKey = _config.getRecoveryKey();
    return recoveryKey;
  }

  Future<String?> getPaymentToken() async {
    try {
      return await _gateway.getPaymentToken();
    } catch (e) {
      _logger.severe("Failed to get payment token", e);
      return null;
    }
  }

  Future<void> _setTwoFactor(bool enabled) async {
    await _preferences.setBool(keyHasEnabledTwoFactor, enabled);
  }

  bool? hasEnabledTwoFactor() {
    return _preferences.getBool(keyHasEnabledTwoFactor);
  }

  bool hasEmailMFAEnabled() {
    return _preferences.getBool(kIsEmailMFAEnabled) ?? false;
  }

  Future<void> setEmailMFAStatus(bool isEnabled) async {
    await _preferences.setBool(kIsEmailMFAEnabled, isEnabled);
  }

  Future<void> updateEmailMFA(bool isEnabled) async {
    try {
      await _gateway.updateEmailMFA(isEnabled: isEnabled);

      await _preferences.setBool(kIsEmailMFAEnabled, isEnabled);

      final UserDetails? profile = getCachedUserDetails();
      if (profile != null && profile.profileData != null) {
        profile.profileData!.isEmailMFAEnabled = isEnabled;
        await _preferences.setString(keyUserDetails, profile.toJson());
      }
      Bus.instance.fire(UserDetailsChangedEvent());
    } catch (e) {
      _logger.severe("Failed to update email mfa", e);
      rethrow;
    }
  }
}
