import 'package:flutter_test/flutter_test.dart';
import 'package:janusvault/core/sync/sync_protocol.dart';

void main() {
  group('SyncMessage Tests', () {
    test('Encodes and decodes authRequest message with deviceId', () {
      final msg = SyncMessage(
        SyncMsgType.authRequest,
        {
          'deviceId': 'ext_a1b2c3d4',
          'challenge': 'dGVzdC1jaGFsbGVuZ2U=',
          'signature': 'dGVzdC1zaWduYXR1cmU=',
        },
      );

      final encoded = msg.encode();
      final decoded = SyncMessage.decode(encoded);

      expect(decoded.type, equals(SyncMsgType.authRequest));
      expect(decoded.payload['deviceId'], equals('ext_a1b2c3d4'));
      expect(decoded.payload['challenge'], equals('dGVzdC1jaGFsbGVuZ2U='));
      expect(decoded.payload['signature'], equals('dGVzdC1zaWduYXR1cmU='));
    });

    test('Encodes and decodes error message with revoked status', () {
      final msg = SyncMessage(
        SyncMsgType.error,
        {'message': 'Device access revoked'},
      );

      final encoded = msg.encode();
      final decoded = SyncMessage.decode(encoded);

      expect(decoded.type, equals(SyncMsgType.error));
      expect(decoded.payload['message'], contains('revoked'));
    });

    test('Encodes and decodes pairingRequest message', () {
      final msg = SyncMessage(
        SyncMsgType.pairingRequest,
        {
          'deviceId': 'peer_device_1',
          'pairingCode': 'XYZ123',
        },
      );

      final encoded = msg.encode();
      final decoded = SyncMessage.decode(encoded);

      expect(decoded.type, equals(SyncMsgType.pairingRequest));
      expect(decoded.payload['deviceId'], equals('peer_device_1'));
      expect(decoded.payload['pairingCode'], equals('XYZ123'));
    });

    test('Encodes and decodes vekRotation and vekRotationAck', () {
      final rotateMsg = SyncMessage(
        SyncMsgType.vekRotation,
        {'newWrappedVek': 'bmV3LXZlaw=='},
      );
      final ackMsg = SyncMessage(
        SyncMsgType.vekRotationAck,
        {'status': 'ok'},
      );

      final decodedRotate = SyncMessage.decode(rotateMsg.encode());
      final decodedAck = SyncMessage.decode(ackMsg.encode());

      expect(decodedRotate.type, equals(SyncMsgType.vekRotation));
      expect(decodedRotate.payload['newWrappedVek'], equals('bmV3LXZlaw=='));
      expect(decodedAck.type, equals(SyncMsgType.vekRotationAck));
      expect(decodedAck.payload['status'], equals('ok'));
    });
  });

  group('RecordMeta & WireRecord Tests', () {
    test('RecordMeta json serialization roundtrip', () {
      final now = DateTime.now().toUtc();
      final meta = RecordMeta(
        uuid: 'entry-uuid-123',
        hash: 'sha256-hash-value',
        lastUpdated: now,
        deleted: false,
      );

      final json = meta.toJson();
      final parsed = RecordMeta.fromJson(json);

      expect(parsed.uuid, equals('entry-uuid-123'));
      expect(parsed.hash, equals('sha256-hash-value'));
      expect(parsed.lastUpdated.toIso8601String(), equals(now.toIso8601String()));
      expect(parsed.deleted, isFalse);
    });

    test('WireRecord json serialization roundtrip', () {
      final now = DateTime.now().toUtc();
      final wire = WireRecord(
        uuid: 'uuid-1',
        encryptedWebsiteName: 'blob1',
        encryptedWebsiteUrl: 'blob2',
        encryptedUsername: 'blob3',
        encryptedPassword: 'blob4',
        createdAt: now,
        lastUpdated: now,
        hash: 'hash-abc',
        deleted: false,
      );

      final json = wire.toJson();
      final parsed = WireRecord.fromJson(json);

      expect(parsed.uuid, equals('uuid-1'));
      expect(parsed.encryptedWebsiteName, equals('blob1'));
      expect(parsed.encryptedPassword, equals('blob4'));
      expect(parsed.hash, equals('hash-abc'));
      expect(parsed.deleted, isFalse);
    });
  });

  group('SyncDiff Computation Tests', () {
    test('Returns empty lists when mine and theirs are identical', () {
      final now = DateTime.now();
      final mine = [
        RecordMeta(uuid: '1', hash: 'h1', lastUpdated: now, deleted: false),
        RecordMeta(uuid: '2', hash: 'h2', lastUpdated: now, deleted: false),
      ];
      final theirs = [
        RecordMeta(uuid: '1', hash: 'h1', lastUpdated: now, deleted: false),
        RecordMeta(uuid: '2', hash: 'h2', lastUpdated: now, deleted: false),
      ];

      final diff = SyncDiff.compute(mine: mine, theirs: theirs);
      expect(diff.uuidsToRequestFromPeer, isEmpty);
      expect(diff.uuidsToSendToPeer, isEmpty);
    });

    test('Identifies records to request from peer and send to peer', () {
      final now = DateTime.now();
      final mine = [
        RecordMeta(uuid: '1', hash: 'h1', lastUpdated: now, deleted: false),
      ];
      final theirs = [
        RecordMeta(uuid: '2', hash: 'h2', lastUpdated: now, deleted: false),
      ];

      final diff = SyncDiff.compute(mine: mine, theirs: theirs);
      expect(diff.uuidsToRequestFromPeer, equals(['2']));
      expect(diff.uuidsToSendToPeer, equals(['1']));
    });

    test('Handles divergent records using newer lastUpdated timestamp', () {
      final t1 = DateTime(2026, 1, 1, 10, 0);
      final t2 = DateTime(2026, 1, 1, 12, 0);

      // Entry 1: peer is newer -> should request from peer
      // Entry 2: local is newer -> should send to peer
      final mine = [
        RecordMeta(uuid: '1', hash: 'h1_old', lastUpdated: t1, deleted: false),
        RecordMeta(uuid: '2', hash: 'h2_new', lastUpdated: t2, deleted: false),
      ];
      final theirs = [
        RecordMeta(uuid: '1', hash: 'h1_new', lastUpdated: t2, deleted: false),
        RecordMeta(uuid: '2', hash: 'h2_old', lastUpdated: t1, deleted: false),
      ];

      final diff = SyncDiff.compute(mine: mine, theirs: theirs);
      expect(diff.uuidsToRequestFromPeer, equals(['1']));
      expect(diff.uuidsToSendToPeer, equals(['2']));
    });
  });

  group('Strict Domain Matching Heuristic Tests', () {
    bool isDomainMatch(String pageDomain, String entryUrl, String entryName) {
      if (entryUrl.trim().isEmpty) {
        return entryName.toLowerCase() == pageDomain.toLowerCase();
      }

      String normalizedUrl = entryUrl.trim().toLowerCase();
      if (!normalizedUrl.startsWith('http://') && !normalizedUrl.startsWith('https://')) {
        normalizedUrl = 'https://$normalizedUrl';
      }

      try {
        final parsed = Uri.parse(normalizedUrl);
        final entryHost = parsed.host.toLowerCase();
        if (entryHost.isEmpty) return false;

        final target = pageDomain.toLowerCase();
        if (entryHost == target) return true;
        if (entryHost.endsWith('.$target')) return true;
        if (target.endsWith('.$entryHost')) return true;
        return false;
      } catch (_) {
        return false;
      }
    }

    test('Matches exact domain', () {
      expect(isDomainMatch('github.com', 'https://github.com/login', 'GitHub'), isTrue);
      expect(isDomainMatch('netflix.com', 'https://netflix.com', 'Netflix'), isTrue);
    });

    test('Matches subdomains safely', () {
      expect(isDomainMatch('login.github.com', 'https://github.com', 'GitHub'), isTrue);
      expect(isDomainMatch('github.com', 'https://auth.github.com', 'GitHub'), isTrue);
    });

    test('Rejects unrelated or deceptive domains', () {
      expect(isDomainMatch('attacker-github.com', 'https://github.com', 'GitHub'), isFalse);
      expect(isDomainMatch('github.com.evil.org', 'https://github.com', 'GitHub'), isFalse);
      expect(isDomainMatch('example.org', 'https://example.com', 'Example'), isFalse);
      expect(isDomainMatch('reddit.com', 'https://netflix.com', 'Netflix'), isFalse);
    });
  });
}
