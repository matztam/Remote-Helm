import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_helm/helm/route_catalog.dart';

// The exact tGetObject (0x0c) request and tGetObjectReply (0x0d) response
// captured (PCAPdroid) from the real ActiveCaptain app fetching a
// plotter-created route named "YYYY" — see route_catalog.dart's top doc
// comment. Used as a golden fixture: proves fetchObject can decode a real
// captured reply, independent of whether the (unverified) empty-list
// catalog request in fetchCatalog is correct.
const _capturedGetObjectRequest =
    '1d0000000c0020984dd4320f0300001701010101071110895dc92b5af14f4dba62bc39cd077e53';
const _capturedGetObjectReply =
    '1d0000000d00f801984dd4320f030000ee0101010105071110895dc92b5af14f4dba62bc39cd077e5'
    '30dfcb3f2d6791102190127ca010201000fc401c2011f8b08000000000004034dcddd0ac2300c0560'
    '9f25d71d34699b367d131119dd8f30709bccce9bb177b720ea7297c397930da634f610e15c0614ace'
    'bd0952d88eb5aa1a672e98695bdd9ae6a1253d5b446da4e7bdf3b53745af35c7f0af2b2f60a1ecb5c9'
    '257bf402405e330d5870415bc9e398d0f8886984950d873399a87293f215e36b8cf13444411428'
    '3a2e09e324466eb1985fcaebe82b47664e528bc76c11e05213b5d7efe3ac407a2a3708683d57f114'
    '80469bfeea7373f6c22ff17010000';

const _routeUuid = '895dc92b-5af1-4f4d-ba62-bc39cd077e53';

/// Arbitrary but fixed `remote_ver` bytes a fake server's tCatalogSyncReply
/// hands back — [RouteCatalogConnection.fetchObject] now caches and reuses
/// whatever `remote_ver` a real (or fake) server returns instead of
/// picking its own value (see [RouteCatalogConnection.fetchObject]'s own
/// doc comment), so a fake server needs to hand back *something* here
/// for a realistic exchange, but the actual bytes don't matter for these
/// tests beyond "gets echoed back correctly, and the golden fixture
/// reply's own correlationId field is patched to match it".
final _fakeRemoteVer = Uint8List.fromList([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]);

// A real captured tCatalogSyncReply (0x0f) on topicRoutes, 101 records —
// re-extracted from a fresh capture while re-investigating fetchCatalog's
// registration-timing bug (see route_catalog.dart's top doc comment). Used
// as a golden fixture for fetchCatalog's reply parsing, independent of
// whether the (still-unverified) N=0 request header this file sends is
// what a real plotter expects.
const _capturedCatalogSyncReply =
    '1d0000000f008d1502a74dd432080300009c4dd4320e030000984dd4320f030000f21402014a'
    '091c02071110295c176977eb4ed784a9f1f27a01f1940df6a2f0e51302071110d394f591c50d'
    '4f13a497900940c3b2390df993c9d3390207111028103258ac2a4993821f4eb63755e49f0ded'
    'ddeaef230207111093ad0de32681403c8bef42ef18c7c0270dde9fa2ea1e02071110637905a5'
    '24e241e79a7d2ca7fa9c0e030db5879cf91602071110ded9fa4e040c4298b342e0f348e0162c'
    '0dfafcc2961202071110494f785bfdd942cbb7b0173dc7a4d0a50df1d7cfbc12020711101028'
    'ac246e104881b155a356af8b9dc70d8accc2e715020711107e0a90aca8b94b3892bd8fac2a87'
    '29520de68dbfd71802071110f523fc27f0014389bc8867f9d7e571740decedb6c01b02071110'
    '7ac118680d6b445d9221bb8638d330100deea9bbfe1d0207111052bb0dce6d7f48a08f777b4a'
    'cfa2f3af0de0d890a05602071110797009d3cf0a42acb24bf425026529f50ddbe2e29e180207'
    '1110b438cb8670e541869ac162e4dadcf4270df4e6b8a41802071110cf92160f5adc4be0abc9'
    '7ccefc99f18b0ef2d1b0908001020711103efa8666957b4104a785364ac501ae2b0dcccae88b'
    '350207111095e6bfc4f09b462aa48a8d8c031600180db39ca29c1702071110d39b68deadb943'
    'cdaae736b63600cf640df1bd93df1e020711102dc7543141d34fe8a367e423b9d85fea0ddf93'
    'ace81b020711103d87b2ce1fb6456a9f15375b4dbe2f420dd2ddb1af190207111040838f86aa'
    '4842c8aaa9f698a287c0150df4e3a3b11702071110e425df9464124fc2ad4c94d34228bc940d'
    'f5f79fbe1902071110cba07a871d57427686e8ac377efd5d750dfaf9c7ae1002071110d0eb31'
    'b387a248798d94363ba9b86c790eabc3c5de920102071110de10b87dc644496e9745d51c38f5'
    '89a70d90f2a4bf1802071110b540567e98564dfb84db8180d7793c970d8fa9e7ee5402071110'
    '5994a0f74e03417eb7c3ba7efeb6ae240efba5e8bd9d0102071110e2af17cb27f34faf965eb5'
    '751620ca300da0acf9d42b020711106d62db81ad1043699bf4cd085b0266be0dbfedd6891c02'
    '07111012203525a10549e49b7c36cf71989c4a0dc2b8e4c0170207111052371392d70744baa2'
    '4444c1b822ccb90df7a8a9941302071110378344478c7e4e7eb16f9d1c105ee6570d83bb8bf7'
    '2f020711103e92885860c24b6d8d8d72f4ab64c9d40d949aefc72802071110935626f18b6241'
    '9993be42b91035d7fb0ddac483ba2b0207111054d30660bb554d8da6a0f72b5b80cfb50df9b9'
    'aaf82902071110cd26736112c94f2a93afb7e4a91a62e30d81e5c1b13502071110274ab638aa'
    '714d9ba6846eef011bf6770d8eb6f6c61702071110247ba84fbb1f44d3b74451a7029763660d'
    '98e09da91c0207111083f9a8609f6a4966934ed00c91565cd90edfecd599e70102071110624b'
    'f58538ca4826b73e6d812eb7819b0dd7daf5a61002071110f30a6f78f8b445c0b32c0ed06ef1'
    'be280efc9890cdc001020711100b8f586dc7c04649b0bc7163816a06fb0dd1be9dd33c020711'
    '102255281ddc0f471ebbdf6de0320405ae0efc9593f29b0302071110a3b974e8d7bd4042a646'
    '4514617897190e9ccea7a3ff010207111011a1c2ac0a48459ab8498cf77b436b5f0dc9c6b8e9'
    '1902071110b3c46e4fb5ef43e7a2d21c49cf2bcb050e83dcbaf8840102071110885009ec71a1'
    '4d918150c129da4504680d98c5f8a31c02071110c2996e1566404681a1631a4053bbff630de3'
    'd6ccc1120207111031ea56756ad749fa8dae6d5255d1a2a50dc6fdf9cd2d02071110dca866c3'
    '518348d7a0a2dbff3aca69260de9b890862f0207111064d6e8526a57426c973abbefd0f7b508'
    '0d97b9c0892a02071110c003fc2c678743c7b5c9ed01b978c77a0d94c1fdd024020711100eab'
    'f27676e641958d41af162d8753d20dc2a1eccf3c02071110f429bcac59f9429888d70482f744'
    'cad60d94b094a72402071110d92c28eb8e834de4a4455f27166444bc0d9d96ebd72702071110'
    'b32a399bb8cd4a2ca595b23fc79bdc830ecca29a9fe80802071110c69223d9dbfa4661837e08'
    'a2cd0c1da60df3c093cb23020711101080e14d845f4567a49e5a559f657f100de2b78da03902'
    '071110746d31535e7a4604b68b9d1ceab244cf0db7a69cbf2302071110809df9ae48e5433ead'
    '43f080cee13e6f0de5dabaf32f0207111037a22a9afc184df885e35f300ad0ad490dc4979d83'
    '4f02071110d8b7e0b4faec49f2b778476f147d19420ec5efb2f2e30102071110a459b3b82421'
    '4a4488a6657bdfb14b950de9dbbf863b020711101acef99292204a658604e85fa6e4980c0ee1'
    'dfcbbdbb0202071110644e6b0544834b4faac03094577e67080ece9aa59cd20302071110bcce'
    '5f748f16481698dc89bc87c39ba90e94999cd68602020711100e54da7fc0014113a08ec7ac32'
    '314f520daab4ffb33302071110924df35e649c417db889ae48099239280dadacecaa2e020711'
    '1015f27d53d14a4261abbafd8334c1fa8a0dd3ead7d82b0207111046ee78f197054167884b75'
    'c87286ef440edbc2d1b2f602020711101f6e0eb62fc04721b4965f15c50890880dedeceff421'
    '02071110a662b53c16d64abd81386c84544100c40dfcdee1ec24020711103a2d29f0d5824ebf'
    '877aff9f503e52110ec2d787a9b00102071110895dc92b5af14f4dba62bc39cd077e530dfcb3'
    'f2d679020711101201fd4397f2493c871f97984f03baeb0dcf9ba1966002071110bca4bae031'
    '0b4ac7a2aa69f4ad6682ff0da9a7ddc73f02071110fefcc77b52c54d2e88d275b185b7f9780d'
    'c0c893ea2d020711108582b01fc1844e0f979deab19f1e383a0dd2d6ddff26020711100c6c97'
    '1a4ad84e33826eb7120947d2220d8e8cb7a72f0207111077670134068f4a11969b3c0f59f209'
    'be0ddec8c3a92c02071110087269d3b07244eaae6971d24081b5c90dbabe92e02b020711104e'
    'bc92c054ae4cb592dc90d67f1b757a0d86888c85210207111067f736a2d02c4eaa95819edc91'
    'a9c8a30d9dab8cf92d02071110da155bff6ff34731a0325e33fd13cc520ddfbff3ae3c020711'
    '10eca791a1acc84b0395eacd7c48f587b40dac85adae3f02071110d7226181275c4d7b9f7ab2'
    '3ec4c888920d8f9d87bd3d02071110058e9326d3cc4ca5908bee5a30b508650df0c680942e02'
    '0711105c04a3e04b8a46de8c8ebee4131cf9520d93e783be2f0207111049740d6a8ecd48b0bd'
    '485ab889b30a7f0dcb8daaaa29020711103fc3fadfacd84be6b051cfb4aa4a520f0dedea8791'
    '220207111008879b4ce82d4b02b4de9bacc55de1770ddc9cdcfe2402071110cf852e64e7284a'
    '0b8d86e2aa2a5bac320dd3d582ed2c02071110c31e7944abf74d19b5fafe5929a350b30de9d4'
    '959f3d020711108ffadaedf1d24635989b97254299cd050de8a7b1ed4802071110ffc2f3a1c8'
    'f04d988f9a7742b7480f2e0ec5ff8ea0b00e0207111004c6d98dbc084d6288de549525481626'
    '0ed7f69cfdc20202071110fd4bca0c29944e84960f26dae0e6b9a90d9ea1c39f3e020711106a'
    '7798b57c694ff1a27d9f6ee5ab0f700ddade9cbd4202071110f1451b3924ae4f209e360102c3'
    'cd95670d8ab3afce33020711108ffc43c6788d46829b9ec53ee117dbdb0de3f7d7bf38020711'
    '10959ff271c2564243b0c568eda3acb9250df3c0cc883b0207111025668afe032f492f85d96c'
    '198d6f1f1d0d81e78fbd3f';

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Returns how many bytes an unsigned LEB128 varint starting at [offset]
/// occupies (i.e. up to and including the first byte with its
/// continuation bit clear).
int _leb128Length(Uint8List bytes, int offset) {
  var i = offset;
  while (bytes[i] & 0x80 != 0) {
    i++;
  }
  return i - offset + 1;
}

/// Decodes the unsigned LEB128 varint starting at [offset].
int _leb128Value(Uint8List bytes, int offset) {
  var result = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    final byte = bytes[i];
    result |= (byte & 0x7f) << shift;
    i++;
    if (byte & 0x80 == 0) break;
    shift += 7;
  }
  return result;
}

/// Finds the first occurrence of [hex]-decoded bytes within [haystack].
int _findHex(Uint8List haystack, String hex) {
  final needle = _hexToBytes(hex);
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// Wraps a raw inner-message payload (as captured, without the outer
/// `MSG*` framing) into the outer frame [RouteCatalogConnection] expects.
Uint8List _wrapMsgFrame(Uint8List innerPayload) {
  final out = Uint8List(8 + innerPayload.length);
  out.setRange(0, 4, [0x4D, 0x53, 0x47, 0x2A]);
  ByteData.view(out.buffer).setUint32(4, innerPayload.length, Endian.little);
  out.setRange(8, 8 + innerPayload.length, innerPayload);
  return out;
}

void main() {
  setUpAll(() {
    // Real plotter needs a real ~5s delay between preamble keepalives (see
    // route_catalog.dart's _ensurePreamble); a fake server has no such
    // requirement, so skip the wall-clock wait in tests.
    RouteCatalogConnection.preambleKeepaliveDelay = Duration.zero;
  });

  test('fetchObject decodes a real captured tGetObjectReply byte-for-byte', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedRequests = <Uint8List>[];

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        // Frames arrive one at a time here (small enough that TCP won't
        // fragment them in a loopback test), but fetchObject now sends two
        // in sequence (tRegisterTopic, then tGetObject) — loop so both get
        // handled even if they arrive in the same chunk.
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);

          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) {
            // Plain keepalive (part of _ensurePreamble's 0x29 sequence) —
            // no length field, no reply expected.
            continue;
          }
          if (msgType == tRegisterTopic) {
            // Real reply body is always the fixed 08 00 00 00 00 00 00 00 —
            // no correlation id of its own (see route_catalog.dart's
            // _registerTopic doc comment).
            final replyInner = Uint8List(6 + 8);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
            replyInner[6] = 8;
            client.add(_wrapMsgFrame(replyInner));
            continue;
          }
          if (msgType == tCatalogSync) {
            // fetchObject now syncs first (to get a real remote_ver — see
            // fetchObject's own doc comment) if this connection hasn't
            // already. Minimal empty tCatalogSyncReply, matching the same
            // shape the other tests in this file use: correlation id at
            // leb128PrefixLength + 1 (a 1-byte leb128 prefix here, so
            // offset 2), and a remote_ver 16 bytes further in.
            final requestRest = request.sublist(6);
            final requestCorrelationId = requestRest.sublist(1, 9);
            final replyRest = Uint8List(2 + 8 + 16 + 8)
              ..[0] = 0
              ..[1] = 0
              ..setRange(2, 10, requestCorrelationId)
              ..setRange(26, 34, _fakeRemoteVer);
            final replyInner = Uint8List(6 + replyRest.length);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tCatalogSyncReply, Endian.little);
            replyInner.setRange(6, 6 + replyRest.length, replyRest);
            client.add(_wrapMsgFrame(replyInner));
            continue;
          }

          receivedRequests.add(request);
          // fetchObject now uses the cached remote_ver (from the
          // tCatalogSync exchange above) as this field, not a
          // self-chosen correlation id — the canned reply must echo
          // back whatever the request actually used, same as before.
          final requestCorrelationId = request.sublist(7, 15);
          final reply = _hexToBytes(_capturedGetObjectReply);
          reply.setRange(8, 16, requestCorrelationId);
          client.add(_wrapMsgFrame(reply));
        }
        buf.clear();
        buf.add(bytes);
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);

    final result = await conn.fetchObject(topicRoutes, _routeUuid, timeout: const Duration(seconds: 2));

    expect(result.name, 'YYYY');
    expect(result.uuid, _routeUuid);
    expect(result.points, hasLength(4));
    // The real reply's JSON includes a "vstamp" number (see this file's
    // top doc comment's "GetObject" section, which documents the JSON
    // shape with a placeholder "vstamp": 12345 -- this capture's actual
    // value) -- used by deleteEntry as del_vstamp (see route_catalog.dart's
    // deleteEntry/DownloadedObject doc comments).
    expect(result.vstamp, 32662919676);
    // From the real GPX export of the same plotter (garmin_export.gpx),
    // confirmed to match the semicircle-decoded capture to ~1e-11 degrees.
    expect(result.points[0].lat, closeTo(55.7197010424, 1e-9));
    expect(result.points[0].lon, closeTo(10.0516888406, 1e-9));
    expect(result.points[3].lat, closeTo(55.7253994793, 1e-9));
    expect(result.points[3].lon, closeTo(10.1032812148, 1e-9));

    // Sanity-check our own request encoding against the real captured
    // request for the same UUID (correlation id will differ, since that's
    // a counter this client owns — everything else should match).
    expect(receivedRequests, hasLength(1));
    final captured = _hexToBytes(_capturedGetObjectRequest);
    final sent = receivedRequests.single;
    expect(sent.length, captured.length);
    // topicId + msgType (first 6 bytes) must match exactly.
    expect(sent.sublist(0, 6), captured.sublist(0, 6));
    // The marker + UUID (last 23 bytes) must match exactly too.
    expect(sent.sublist(sent.length - 23), captured.sublist(captured.length - 23));
  });

  test('concurrent fetchObject calls for the same topic are serialized, not raced', () async {
    // Regression test for two 2026-08-07 bugs, both from the same root
    // cause: a catalog-browsing UI that lazily fires one fetchObject per
    // visible row (see route_catalog_dialog.dart) starts several fetchObject
    // calls for the same topic close together — worse, in a burst, under
    // fast scrolling.
    // 1. Each call used to independently see no cached remote_ver yet and
    //    race to register the topic / sync its own remote_ver, corrupting
    //    the single-reply-per-topic exchange. Fixed by _syncInFlightByTopic
    //    (via _ensureTopicReady): only one registration+sync ever runs per
    //    topic, shared by every concurrent caller.
    // 2. Even after (1), every fetchObject call on a topic uses the *same*
    //    remote_ver as its correlation id (by design), and replies are
    //    matched only by (topicId, correlationId) — so two requests in
    //    flight at once for different uuids on the same topic were
    //    indistinguishable, and could resolve to the wrong caller or time
    //    out. Fixed by _enqueueGetObject: only one tGetObject is ever in
    //    flight per topic: each call's send+await is chained after the
    //    previous one's completion.
    // Both bugs live-observed together as: wrong/missing names, and the
    // plotter's "User data sharing is disabled" lockout recurring under
    // fast scrolling even after fix (1) alone.
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Only counted for topicRoutes — connect()'s preamble registers several
    // other topics too (see _ensurePreamble), which is expected and not
    // what this test is checking.
    var registerCount = 0;
    var syncCount = 0;
    final getObjectRequests = <Uint8List>[];
    final getObjectRequestTimes = <DateTime>[];

    // Ignores writes failing after the test's addTearDown(conn.close) has
    // already torn down the socket — the fixture still has a couple of
    // preamble keepalives in flight at that point, which is harmless and
    // not what this test is checking.
    void safeAdd(Socket client, Uint8List data) {
      try {
        client.add(data);
      } on SocketException {
        // ignore
      }
    }

    serverSub = fakeServer.listen((client) {
      client.done.catchError((Object _) {});
      final buf = BytesBuilder(copy: false);
      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);

          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) {
            continue;
          }
          if (msgType == tRegisterTopic) {
            if (topicId == topicRoutes) registerCount++;
            final replyInner = Uint8List(6 + 8);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
            replyInner[6] = 8;
            safeAdd(client, _wrapMsgFrame(replyInner));
            continue;
          }
          if (msgType == tCatalogSync) {
            if (topicId == topicRoutes) syncCount++;
            final requestRest = request.sublist(6);
            final requestCorrelationId = requestRest.sublist(1, 9);
            final replyRest = Uint8List(2 + 8 + 16 + 8)
              ..[0] = 0
              ..[1] = 0
              ..setRange(2, 10, requestCorrelationId)
              ..setRange(26, 34, _fakeRemoteVer);
            final replyInner = Uint8List(6 + replyRest.length);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tCatalogSyncReply, Endian.little);
            replyInner.setRange(6, 6 + replyRest.length, replyRest);
            safeAdd(client, _wrapMsgFrame(replyInner));
            continue;
          }

          // tGetObject: echo back the same golden reply fixture (its actual
          // uuid doesn't matter for this test — only that each request gets
          // its own correctly-correlated reply back) with the request's own
          // remote_ver-derived correlation id patched in, same as the
          // single-fetchObject test above.
          getObjectRequests.add(request);
          getObjectRequestTimes.add(DateTime.now());
          final requestCorrelationId = request.sublist(7, 15);
          final reply = _hexToBytes(_capturedGetObjectReply);
          reply.setRange(8, 16, requestCorrelationId);
          if (getObjectRequests.length == 1) {
            // Deliberately delay the first reply — if fetchObject calls
            // aren't serialized per topic, the second request would already
            // have been sent well before this fires, which is exactly what
            // this test checks below via getObjectRequestTimes.
            Future<void>.delayed(const Duration(milliseconds: 200), () => safeAdd(client, _wrapMsgFrame(reply)));
          } else {
            safeAdd(client, _wrapMsgFrame(reply));
          }
        }
        buf.clear();
        buf.add(bytes);
      }, onError: (Object _) {});
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);

    // Fire two fetchObject calls for the same topic concurrently — the
    // exact pattern two lazily-built ListView rows produce — before either
    // has had a chance to register the topic, sync a remote_ver, or get
    // its tGetObject reply back.
    const otherUuid = '11111111-2222-3333-4444-555555555555';
    final results = await Future.wait([
      conn.fetchObject(topicRoutes, _routeUuid, timeout: const Duration(seconds: 2)),
      conn.fetchObject(topicRoutes, otherUuid, timeout: const Duration(seconds: 2)),
    ]);

    for (final result in results) {
      expect(result.name, 'YYYY');
      expect(result.points, hasLength(4));
    }
    // The whole point of the fix: only one registration and one sync for
    // the topic, no matter how many concurrent fetchObject calls needed it.
    expect(registerCount, 1);
    expect(syncCount, 1);
    expect(getObjectRequests, hasLength(2));
    // The other half of the fix: the second tGetObject must not have been
    // sent until after the (deliberately delayed) first reply went out —
    // otherwise both requests would share the same remote_ver-derived
    // correlation id in flight at once, and _awaitGetObjectReply's
    // (topicId, correlationId) matching couldn't tell their replies apart
    // (see _enqueueGetObject's doc comment in route_catalog.dart).
    expect(getObjectRequestTimes[1].difference(getObjectRequestTimes[0]).inMilliseconds, greaterThanOrEqualTo(150));
  });

  test('fetchObjects sends a byte-exact real batch tGetObject request and decodes a real batch reply', () async {
    // The 118 real waypoint uuids from the same capture as
    // waypoints_batch_get_object_reply.bin, in request order — see
    // route_catalog.dart's fetchObjects doc comment for how this format
    // (LEB128-length-prefixed, not the fixed-width framing used
    // elsewhere in this file) was derived and confirmed.
    const uuids = [
      '82b6b0c6-25ec-4fdf-9173-5f4e49e6a26b',
      '73ddfd6a-7089-456f-9dd1-13990a9b93ef',
      'c54d7f1b-d1c9-4cf5-a85b-011f92258d2f',
    ];
    // The real capture's request for the FULL 118-uuid list, byte-for-byte
    // (rest, i.e. everything after [topicId][msgType]) — used to check
    // this client reproduces the exact wire format for a request this
    // size, independent of which/how-many uuids a given test asks for.
    const realFullRequestHexPrefix =
        'c5121b4dd43271020000bb120101760107111082b6b0c625ec4fdf91735f4e49e6a26b'
        '0107111073ddfd6a7089456f9dd113990a9b93ef01071110c54d7f1bd1c94cf5a85b01'
        '1f92258d2f';

    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Uint8List? receivedRequest;

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);

          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) continue;
          if (msgType == tRegisterTopic) {
            final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
            final replyInner = Uint8List(6 + 8);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
            replyInner[6] = 8;
            client.add(_wrapMsgFrame(replyInner));
            continue;
          }

          receivedRequest = request;
          // Real reply, with its own correlation id overwritten to match
          // whatever this request actually used (a counter this client
          // owns) — same pattern as the other real-capture-fixture tests
          // in this file. The correlation id sits right after each
          // message's own outer LEB128 length prefix — 1-3 bytes
          // depending on that message's total remaining length, not a
          // fixed offset (this request's 3-uuid list uses a 2-byte
          // prefix; the fixture reply's real 118-object payload needs
          // 3 bytes), so it's decoded rather than assumed.
          final reply = File('test/fixtures/waypoints_batch_get_object_reply.bin').readAsBytesSync();
          final requestBody = request.sublist(6);
          final requestPrefixLen = _leb128Length(requestBody, 0);
          final requestCorrelationId = requestBody.sublist(requestPrefixLen, requestPrefixLen + 8);
          final replyPrefixLen = _leb128Length(reply, 0);
          reply.setRange(replyPrefixLen, replyPrefixLen + 8, requestCorrelationId);
          final replyInner = Uint8List(6 + reply.length);
          replyInner.setRange(0, 4, request.sublist(0, 4)); // topicId
          ByteData.view(replyInner.buffer).setUint16(4, tGetObjectReply, Endian.little);
          replyInner.setRange(6, 6 + reply.length, reply);
          client.add(_wrapMsgFrame(replyInner));
        }
        buf.clear();
        buf.add(bytes);
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);

    final results = await conn.fetchObjects(topicWaypoints, uuids, timeout: const Duration(seconds: 5));

    // The real batch reply bundles 118 gzip+JSON objects; this test's
    // request only asked for 3 uuids, but the fixture reply is the real
    // capture's full 118-object reply (there's no per-uuid filtering in
    // the wire format itself — the plotter just replies with whatever it
    // decides to bundle), so all 118 should still decode successfully.
    expect(results, hasLength(118));
    expect(results.every((o) => o.points.isNotEmpty), isTrue);

    // Verify this client's own request for the first 3 real uuids
    // reproduces the real capture's wire bytes exactly (own correlation
    // id aside), confirming the LEB128 framing derivation end-to-end,
    // not just in isolation.
    expect(receivedRequest, isNotNull);
    final sentBody = receivedRequest!.sublist(6);
    final expectedPrefix = _hexToBytes(realFullRequestHexPrefix);
    // Outer LEB128 length prefix + correlation id length differ (this
    // request is for 3 uuids, not 118), so only compare from the first
    // per-entry marker onward — i.e. skip both requests' own
    // uuids.length-dependent header and align on real uuid bytes.
    final sentMarkerIdx = _findHex(sentBody, '01071110');
    final expectedMarkerIdx = _findHex(expectedPrefix, '01071110');
    expect(sentMarkerIdx, greaterThanOrEqualTo(0));
    expect(expectedMarkerIdx, greaterThanOrEqualTo(0));
    expect(
      sentBody.sublist(sentMarkerIdx),
      expectedPrefix.sublist(expectedMarkerIdx),
    );
  });

  test('fetchObjects sends more than 100 uuids as a single request, no chunking', () async {
    // Regression test for the 2026-08-08 finding: fetchObjects used to
    // split >100 uuids into multiple sequential batch tGetObject requests
    // (chunked, with a re-sync in between for a fresh remote_ver). Live
    // testing found that re-sync step itself gets no reply at all, every
    // time — chunking was the bug, not the fix. The real app never chunks
    // (a real capture sent all 118 real waypoint uuids in one request,
    // and a live 118-uuid single-batch fetchObjects call succeeded once
    // this client stopped chunking) — see fetchObjects' own doc comment
    // for the full story. This test locks in "no chunking, ever": 150
    // fake uuids must all end up in exactly one tGetObject request.
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var getObjectRequestCount = 0;
    var lastRequestedUuidCount = -1;

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);

          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) continue;
          if (msgType == tRegisterTopic) {
            final replyInner = Uint8List(6 + 8);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
            replyInner[6] = 8;
            client.add(_wrapMsgFrame(replyInner));
            continue;
          }

          getObjectRequestCount++;
          final requestBody = request.sublist(6);
          final requestPrefixLen = _leb128Length(requestBody, 0);
          final requestCorrelationId = requestBody.sublist(requestPrefixLen, requestPrefixLen + 8);
          // Decode how many uuids this one request actually listed, to
          // confirm it's the full 150, not a truncated chunk.
          final bLenOffset = requestPrefixLen + 8;
          final bLenConsumed = _leb128Length(requestBody, bLenOffset);
          final bStart = bLenOffset + bLenConsumed;
          lastRequestedUuidCount = _leb128Value(requestBody, bStart + 2);

          final reply = _hexToBytes(_capturedGetObjectReply);
          reply.setRange(8, 16, requestCorrelationId);
          client.add(_wrapMsgFrame(reply));
        }
        buf.clear();
        buf.add(bytes);
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);

    final uuids = List.generate(
      150,
      (i) => '00000000-0000-0000-0000-${i.toRadixString(16).padLeft(12, '0')}',
    );
    final remoteVer = Uint8List.fromList([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]);

    await conn.fetchObjects(topicRoutes, uuids, remoteVer: remoteVer, timeout: const Duration(seconds: 3));

    expect(getObjectRequestCount, 1);
    expect(lastRequestedUuidCount, 150);
  });

  test('fetchCatalog parses a real captured tCatalogSyncReply without waiting on registration replies', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final receivedMsgTypes = <int>[];

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      final pendingRegistrations = <int>[]; // topicIds registered, replied to at the end
      var registrationsReplied = false;

      void replyToRegistrationsOnce() {
        if (registrationsReplied || pendingRegistrations.isEmpty) return;
        registrationsReplied = true;
        for (final topicId in pendingRegistrations) {
          final replyInner = Uint8List(6 + 8);
          ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
          ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
          replyInner[6] = 8;
          client.add(_wrapMsgFrame(replyInner));
        }
      }

      // _fetchCatalog now runs a full tCatalogSync-then-batch-tGetObject
      // cycle for every OTHER registered topic (0x4, topicWaypoints) before
      // ever touching topicRoutes — see route_catalog.dart's _fetchCatalog
      // doc comment for why. This fake server answers each tCatalogSync
      // with an empty (0-entry) reply for every topic except topicRoutes,
      // which gets the real captured 101-record fixture; an empty reply
      // means [fetchCatalog] never sends a batch tGetObject for that topic
      // (empty entries -> nothing to fetch), so no tGetObjectReply handling
      // is needed here for those.
      void replyToCatalogSync(int topicId, Uint8List requestRest) {
        final correlationId = requestRest.sublist(1, 9); // 1-byte leb length, then 8-byte corrId
        if (topicId == topicRoutes) {
          final reply = _hexToBytes(_capturedCatalogSyncReply);
          reply.setRange(9, 17, correlationId);
          client.add(_wrapMsgFrame(reply));
          return;
        }
        // Minimal empty tCatalogSyncReply: header bytes matching the real
        // shape closely enough for _parseCatalogEntries to just find no
        // records (any header, since the marker-scan doesn't validate it)
        // AND for _awaitCatalogSyncReply to find the correlation id at the
        // right spot — real captures put it at leb128PrefixLength + 1
        // (not a fixed offset — see _awaitCatalogSyncReply's doc comment).
        // A single-byte leb128 prefix (any value < 128) plus one filler
        // byte puts the correlation id at rest offset 2, matching that.
        final rest = Uint8List(2 + 8)
          ..[0] = 0 // 1-byte leb128 length (value unused/unvalidated by the parser)
          ..[1] = 0 // filler byte, matches real captures' unexplained extra byte
          ..setRange(2, 10, correlationId);
        final replyInner = Uint8List(6 + rest.length);
        ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
        ByteData.view(replyInner.buffer).setUint16(4, tCatalogSyncReply, Endian.little);
        replyInner.setRange(6, 6 + rest.length, rest);
        client.add(_wrapMsgFrame(replyInner));
      }

      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);

          if (request.length < 6) continue;
          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) continue; // plain keepalive
          receivedMsgTypes.add(msgType);

          if (msgType == tRegisterTopic) {
            if (topicId == topicTrack) {
              // **Bug found live 2026-08-07 fetching the real track
              // (topicTrack == 0x4)**: _ensurePreamble now actually waits
              // for 0x4's own registration reply (unlike topicRoutes/
              // topicWaypoints, whose _registerTopic calls still don't
              // wait — that's what the rest of this test still exercises).
              // Reply immediately here, not bundled into
              // replyToRegistrationsOnce() below, so that wait doesn't
              // hang this test.
              final replyInner = Uint8List(6 + 8);
              ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
              ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
              replyInner[6] = 8;
              client.add(_wrapMsgFrame(replyInner));
            } else {
              pendingRegistrations.add(topicId);
            }
            continue;
          }
          if (msgType == tCatalogSync) {
            replyToCatalogSync(topicId, Uint8List.sublistView(request, 6));
          }
        }
        buf.clear();
        buf.add(bytes);
        replyToRegistrationsOnce();
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    RouteCatalogConnection.debugTrace = true;
    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);
    addTearDown(() => RouteCatalogConnection.debugTrace = false);

    final entries = await conn.fetchCatalog(topicRoutes, timeout: const Duration(seconds: 2));

    // The raw reply has 102 marker-scan-parsed records (see the git history
    // of this test for that count's own explanation), but as found live
    // 2026-08-08 (route_catalog.dart's _syncCatalog doc comment), the sync
    // reply also carries a "real object count" field the plotter itself
    // uses to say how many of those raw records are actually real,
    // individually-fetchable objects — the rest are structurally valid but
    // not really fetchable (confirmed live: a single fetchObject for one,
    // in isolation, got no reply at all). This fixture's own such field
    // decodes to 74, so fetchCatalog now trims to that many.
    expect(entries, hasLength(74));
    expect(entries.every((e) => e.topic == topicRoutes), isTrue);
    expect(entries.every((e) => e.isRoute), isTrue);
    // The real "YYYY" route's UUID (also used by the fetchObject test above)
    // must be among the parsed entries.
    expect(entries.map((e) => e.uuid), contains(_routeUuid));

    // fetchCatalog must register topicWaypoints too before ever touching
    // topicRoutes, per every real capture examined (see this file's top doc
    // comment and route_catalog.dart's fetchCatalog doc comment) — and must
    // not have waited for either registration reply before sending
    // tCatalogSync (that's the bug this test guards against regressing).
    final firstRegisterIdx = receivedMsgTypes.indexOf(tRegisterTopic);
    final catalogSyncIdx = receivedMsgTypes.indexOf(tCatalogSync);
    expect(firstRegisterIdx, greaterThanOrEqualTo(0));
    expect(catalogSyncIdx, greaterThan(firstRegisterIdx));
    expect(receivedMsgTypes.where((t) => t == tRegisterTopic).length, greaterThanOrEqualTo(2));
  });

  test('deleteEntry syncs once for prevRemoteVer, sends tDeleteEntry, no verification round-trip', () async {
    // **Rewritten 2026-08-08, twice.** deleteEntry DOES still run one
    // tCatalogSync (to get a real, server-synced prevRemoteVer — a full
    // app-reset capture confirmed this is required, not optional; see
    // deleteEntry's doc comment for the two contradicting captures that
    // led here). What it does NOT do (confirmed by every real capture):
    // a post-delete verification tCatalogSync. This fixture replies to
    // exactly one tCatalogSync with a minimal single-entry reply (route
    // present, so deleteEntry's presence check passes) and otherwise
    // only needs to handle registration and the tDeleteEntry send itself.
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deleteRests = <Uint8List>[]; // every tDeleteEntry's rest, in order
    var catalogSyncCount = 0;

    Uint8List buildCatalogSyncReply(Uint8List correlationId) {
      final uuidBytes = _hexToBytes('895dc92b5af14f4dba62bc39cd077e53');
      final entry = <int>[0x02, 0x07, 0x11, 0x10, ...uuidBytes, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final countExtra = <int>[0x02, 0x01, 1, 0x09, 0x00];
      final tail = <int>[...countExtra, ...entry];
      final rest = <int>[
        0, // 1-byte leb128 length placeholder (unused/unvalidated by the parser)
        0, // filler byte, matches real captures' unexplained extra byte
        ...correlationId,
        ...tail,
      ];
      final replyInner = Uint8List(6 + rest.length);
      ByteData.view(replyInner.buffer).setUint32(0, topicRoutes, Endian.little);
      ByteData.view(replyInner.buffer).setUint16(4, tCatalogSyncReply, Endian.little);
      replyInner.setRange(6, replyInner.length, rest);
      return replyInner;
    }

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      final pendingRegistrations = <int>[];
      var registrationsReplied = false;

      void replyToRegistration(int topicId) {
        final replyInner = Uint8List(6 + 8);
        ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
        ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
        replyInner[6] = 8;
        client.add(_wrapMsgFrame(replyInner));
      }

      void replyToRegistrationsOnce() {
        if (registrationsReplied || pendingRegistrations.isEmpty) return;
        registrationsReplied = true;
        for (final topicId in pendingRegistrations) {
          replyToRegistration(topicId);
        }
      }

      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);
          if (request.length < 6) continue;
          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) continue;

          if (msgType == tRegisterTopic) {
            if (topicId == topicTrack) {
              replyToRegistration(topicId);
            } else {
              pendingRegistrations.add(topicId);
            }
            continue;
          }
          if (msgType == tCatalogSync) {
            catalogSyncCount++;
            final rest = Uint8List.sublistView(request, 6);
            final correlationId = Uint8List.sublistView(rest, rest[0] & 0x80 != 0 ? 2 : 1, (rest[0] & 0x80 != 0 ? 2 : 1) + 8);
            client.add(_wrapMsgFrame(buildCatalogSyncReply(correlationId)));
          } else if (msgType == tGetObject) {
            // deleteEntry now follows tCatalogSync with a batch tGetObject
            // covering the whole (validCount-trimmed) catalog — matching
            // the real app's own merge completion round-trip
            // (see deleteEntry's doc comment, added 2026-08-08 after a
            // live tcpdump comparison against the real capture showed
            // this was the one remaining structural gap). Reply with the
            // real captured single-object tGetObjectReply fixture (same
            // uuid this fixture's catalog has), correlation id patched to
            // match the request — deleteEntry itself doesn't use the
            // result, only needs *a* reply to not time out.
            final requestBody = Uint8List.sublistView(request, 6);
            final requestPrefixLen = _leb128Length(requestBody, 0);
            final requestCorrelationId = requestBody.sublist(requestPrefixLen, requestPrefixLen + 8);
            final reply = _hexToBytes(_capturedGetObjectReply.substring(12)); // strip the real capture's own [topicId][msgType][len] prefix, rebuilt below
            final replyPrefixLen = _leb128Length(reply, 0);
            reply.setRange(replyPrefixLen, replyPrefixLen + 8, requestCorrelationId);
            final replyInner = Uint8List(6 + reply.length);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tGetObjectReply, Endian.little);
            replyInner.setRange(6, 6 + reply.length, reply);
            client.add(_wrapMsgFrame(replyInner));
          } else if (msgType == tDeleteEntry) {
            deleteRests.add(Uint8List.sublistView(request, 6));
          }
        }
        buf.clear();
        buf.add(bytes);
        replyToRegistrationsOnce();
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    RouteCatalogConnection.debugTrace = true;
    RouteCatalogConnection.deletePostMergeDelay = Duration.zero;
    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);
    addTearDown(() => RouteCatalogConnection.debugTrace = false);
    addTearDown(() => RouteCatalogConnection.deletePostMergeDelay = const Duration(seconds: 30));

    const testVstamp = 12345;
    await conn.deleteEntry(topicRoutes, _routeUuid, timeout: const Duration(seconds: 2), vstamp: testVstamp);
    // deleteEntry is now fire-and-forget with no round-trip to await (see
    // its doc comment) — it can return before the fake server's own
    // socket listener has actually processed the just-sent bytes. Give it
    // a moment; this is a test-fixture timing artifact, not something
    // real callers need to work around (a real plotter's TCP stack isn't
    // on the same event loop as this test).
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(catalogSyncCount, 1, reason: 'deleteEntry must run exactly one tCatalogSync (for prevRemoteVer), no more, no post-delete verification one');
    expect(deleteRests, hasLength(1));
    final sentRest = deleteRests.single;

    // Wire format (see route_catalog.dart's deleteEntry doc comment):
    // body[0] is a LEB128 vint (NOT a fixed byte -- root cause fix,
    // 2026-08-09, see the doc comment right above where this field is
    // built) encoding the byte length of everything after itself,
    // followed by prev remote_ver(8) + new remote_ver(8) + a LEB128
    // tail-length vint + the tail itself (counter prefix, fixed uuid
    // marker, target uuid, trailer).
    final tagLeb = sentRest[0];
    expect(tagLeb, lessThan(0x80), reason: 'this fixture keeps the message small enough for a 1-byte LEB128 tag');
    // sentRest.length = lebLen(tag) [1 byte here] + tag (tag's own value
    // equals the byte length of everything after the tag field itself) --
    // verified against 4 distinct real totalLen/tag pairs from 2 separate
    // devices' captures: 49->48, 50->49, 260->258, 805->803. See
    // deleteEntry's doc comment for the full derivation.
    expect(tagLeb, sentRest.length - 1, reason: 'tag must equal the total message length minus its own 1-byte LEB128 width');

    // newRemoteVer's seq (upper 32 bits) must be prevRemoteVer's own seq
    // + 1 -- **root cause fix, 2026-08-09** (see _freshRemoteVerLikeValue's
    // doc comment): confirmed byte-for-byte against all 6 real captured
    // deletes available, after an earlier version of this file concluded
    // (wrongly, from comparing the two 64-bit values as a whole instead of
    // splitting seq/sub first) that they were unrelated.
    final prevRemoteVerSent = Uint8List.sublistView(sentRest, 1, 9);
    final newRemoteVerSent = Uint8List.sublistView(sentRest, 9, 17);
    final prevSeq = ByteData.sublistView(prevRemoteVerSent).getUint64(0, Endian.little) >> 32;
    final newSeq = ByteData.sublistView(newRemoteVerSent).getUint64(0, Endian.little) >> 32;
    expect(newSeq, prevSeq + 1, reason: 'newRemoteVer seq must be prevRemoteVer seq + 1');

    expect(sentRest[17], sentRest.length - 18, reason: 'length byte must equal exactly the remaining bytes');
    expect(
      Uint8List.sublistView(sentRest, 23, 27),
      _hexToBytes('02071110'),
      reason: 'fixed uuid marker + 16-byte length',
    );
    final sentUuidBytes = Uint8List.sublistView(sentRest, 27, 43);
    expect(sentUuidBytes, _hexToBytes('895dc92b5af14f4dba62bc39cd077e53'), reason: 'target uuid must be sent byte-exact');

    // trailer = del_vstamp: a field-tag byte `(fieldId << 3) | lebLen`
    // (fieldId=1, the field right after uuid in the delete message's field
    // list --
    // corrected 2026-08-09, see _buildDeleteTrailer's doc comment; the tag
    // is NOT a bare length byte, that earlier assumption is why every live
    // delete with a del_vstamp present was silently ignored until this was
    // found) followed by that many standard unsigned LEB128 bytes. NOT a
    // checksum, and NOT the vstamp passed in verbatim either. The
    // plotter's vstamp is a packed `(seq << 32) | sub` bitfield (see
    // _incrementVstamp's doc comment) -- deleting increments `seq` by 1
    // and draws a fresh random `sub`, matching the real app's own
    // vstamp-increment logic. So only `seq` is deterministically checkable
    // here; `sub` just needs to be a plausible 32-bit value.
    final trailer = Uint8List.sublistView(sentRest, 43);
    final varintLen = trailer[0] & 0x7;
    expect(trailer[0] >> 3, 1, reason: 'del_vstamp tag byte must encode fieldId=1');
    expect(trailer.length, 1 + varintLen, reason: 'trailer must be exactly the tag byte plus that many varint bytes');
    var decoded = 0;
    var shift = 0;
    for (var i = 0; i < varintLen; i++) {
      final b = trailer[1 + i];
      decoded |= (b & 0x7f) << shift;
      shift += 7;
      if (b & 0x80 == 0) {
        expect(i, varintLen - 1, reason: 'continuation bit must be clear only on the last varint byte');
      } else {
        expect(i, lessThan(varintLen - 1), reason: 'continuation bit must be set on every byte but the last');
      }
    }
    final decodedSeq = (decoded >> 32) & 0xFFFFFFFF;
    final decodedSub = decoded & 0xFFFFFFFF;
    expect(decodedSeq, (testVstamp >> 32) + 1, reason: 'del_vstamp seq must be the input vstamp\'s seq incremented by 1');
    expect(decodedSub, inInclusiveRange(0, 0xFFFFFFFF), reason: 'del_vstamp sub must be a plausible 32-bit value');

    // bytes[18:23] ("01 07 <A> 03 <B>") -- **root cause fix, 2026-08-09**
    // (see _rteDelMsgTagPrefix's doc comment): this is NOT a session
    // counter, it's a field-tag prefix whose last two values are
    // `23 + lebLen` / `21 + lebLen`, where lebLen is del_vstamp's own
    // LEB128 byte length (just decoded above as `varintLen`). Every
    // previous version of this method computed A/B from an unrelated
    // incrementing counter, which happened to match real captures only by
    // coincidence of sample size -- this assertion pins the real,
    // reverse-engineered relationship so a future change can't
    // silently regress back to that guess.
    final prefix = Uint8List.sublistView(sentRest, 18, 23);
    expect(prefix[0], 0x01);
    expect(prefix[1], 0x07);
    expect(prefix[2], 23 + varintLen, reason: 'A = 23 + del_vstamp LEB128 length');
    expect(prefix[3], 0x03);
    expect(prefix[4], 21 + varintLen, reason: 'B = 21 + del_vstamp LEB128 length');
  });

  test('deleteEntry prefers a fresh catalog-sync vstamp over a caller-supplied one on the syncing path', () async {
    // **Regression test for a bug found live 2026-08-10, twice.** The
    // first fix made a caller-supplied `vstamp` fall back to the fresh
    // sync's own value only when the caller passed nothing at all
    // (`resolvedVstamp ??= entry.vstamp`) — but route_catalog_dialog.dart's
    // delete button always passes `object.vstamp` (from whenever that
    // object was first loaded), so the fresh, just-synced value was
    // silently discarded every single time on real hardware, producing a
    // `del_vstamp` built from a stale vstamp that no longer matched the
    // plotter's current state -- structurally correct wire bytes, no
    // exception, but the plotter kept the entry. The fix must make the
    // fresh catalog-sync vstamp win instead. This fixture gives the fake
    // server's tCatalogSyncReply a REAL, decodable vstamp for the target
    // uuid (`0d bd ea c4 de 39`, one of the real captured trailer values
    // documented in `_parseCatalogEntries`'s doc comment) and calls
    // deleteEntry with a deliberately different, wrong `vstamp` (`999`)
    // to prove the sync's own value — not the caller's — ends up in the
    // sent `del_vstamp` field.
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Uint8List? sentRest;

    Uint8List buildCatalogSyncReplyWithVstamp(Uint8List correlationId) {
      final uuidBytes = _hexToBytes('895dc92b5af14f4dba62bc39cd077e53');
      // Real captured trailer (`0d bd ea c4 de 39`, per _parseCatalogEntries's
      // doc comment): length byte 0x0d=13 means _decodeCatalogEntryVstamp
      // requires 13-7=6 bytes to be present after it (even though the
      // LEB128 value itself terminates after 5, on the byte with the clear
      // continuation bit) -- padded with one extra trailing byte so the
      // decoder's own bounds check (`offset + 1 + maxPayloadLen >
      // body.length`) doesn't reject it for running past the fixture's own
      // buffer, matching the 9-byte trailer width the existing
      // `buildCatalogSyncReply` fixture already uses for its own (all-zero,
      // undecodable) trailer.
      final vstampTrailer = _hexToBytes('0dbdeac4de3900000000');
      final entry = <int>[0x02, 0x07, 0x11, 0x10, ...uuidBytes, ...vstampTrailer];
      final countExtra = <int>[0x02, 0x01, 1, 0x09, 0x00];
      final tail = <int>[...countExtra, ...entry];
      final rest = <int>[0, 0, ...correlationId, ...tail];
      final replyInner = Uint8List(6 + rest.length);
      ByteData.view(replyInner.buffer).setUint32(0, topicRoutes, Endian.little);
      ByteData.view(replyInner.buffer).setUint16(4, tCatalogSyncReply, Endian.little);
      replyInner.setRange(6, replyInner.length, rest);
      return replyInner;
    }

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);
      final pendingRegistrations = <int>[];
      var registrationsReplied = false;

      void replyToRegistration(int topicId) {
        final replyInner = Uint8List(6 + 8);
        ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
        ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
        replyInner[6] = 8;
        client.add(_wrapMsgFrame(replyInner));
      }

      void replyToRegistrationsOnce() {
        if (registrationsReplied || pendingRegistrations.isEmpty) return;
        registrationsReplied = true;
        for (final topicId in pendingRegistrations) {
          replyToRegistration(topicId);
        }
      }

      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);
          if (request.length < 6) continue;
          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) continue;

          if (msgType == tRegisterTopic) {
            if (topicId == topicTrack) {
              replyToRegistration(topicId);
            } else {
              pendingRegistrations.add(topicId);
            }
            continue;
          }
          if (msgType == tCatalogSync) {
            final rest = Uint8List.sublistView(request, 6);
            final correlationId = Uint8List.sublistView(rest, rest[0] & 0x80 != 0 ? 2 : 1, (rest[0] & 0x80 != 0 ? 2 : 1) + 8);
            client.add(_wrapMsgFrame(buildCatalogSyncReplyWithVstamp(correlationId)));
          } else if (msgType == tGetObject) {
            final requestBody = Uint8List.sublistView(request, 6);
            final requestPrefixLen = _leb128Length(requestBody, 0);
            final requestCorrelationId = requestBody.sublist(requestPrefixLen, requestPrefixLen + 8);
            final reply = _hexToBytes(_capturedGetObjectReply.substring(12));
            final replyPrefixLen = _leb128Length(reply, 0);
            reply.setRange(replyPrefixLen, replyPrefixLen + 8, requestCorrelationId);
            final replyInner = Uint8List(6 + reply.length);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tGetObjectReply, Endian.little);
            replyInner.setRange(6, 6 + reply.length, reply);
            client.add(_wrapMsgFrame(replyInner));
          } else if (msgType == tDeleteEntry) {
            sentRest = Uint8List.sublistView(request, 6);
          }
        }
        buf.clear();
        buf.add(bytes);
        replyToRegistrationsOnce();
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    RouteCatalogConnection.deletePostMergeDelay = Duration.zero;
    RouteCatalogConnection.debugTrace = true;
    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);
    addTearDown(() => RouteCatalogConnection.deletePostMergeDelay = const Duration(seconds: 30));
    addTearDown(() => RouteCatalogConnection.debugTrace = false);

    // Deliberately wrong/stale: the fresh sync's own vstamp must win over this.
    await conn.deleteEntry(topicRoutes, _routeUuid, timeout: const Duration(seconds: 2), vstamp: 999);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sentRest, isNotNull, reason: 'the delete message must have been sent');
    final trailer = Uint8List.sublistView(sentRest!, 43);
    final varintLen = trailer[0] & 0x7;
    var decoded = 0;
    var shift = 0;
    for (var i = 0; i < varintLen; i++) {
      decoded |= (trailer[1 + i] & 0x7f) << shift;
      shift += 7;
    }
    // The fixture's real captured vstamp trailer (`0dbdeac4de39`) decodes
    // to 15499081021 -- `seq = value >> 32 = 3`, so after deleteEntry's own
    // +1 increment the sent del_vstamp's seq must be 4. The caller-supplied
    // `vstamp: 999` would instead produce seq = (999 >> 32) + 1 = 0 + 1 = 1
    // (999 fits entirely in the low 32 bits) -- these two expected results
    // are deliberately far apart so a mistaken source can't accidentally
    // produce the same seq either way.
    final decodedSeq = (decoded >> 32) & 0xFFFFFFFF;
    expect(decodedSeq, 4, reason: 'del_vstamp seq must come from the fresh sync\'s own vstamp (15499081021 >> 32 = 3, +1 = 4), not the caller-supplied stale vstamp (999 >> 32 = 0, +1 = 1)');
  });

  test('fetchObject throws RouteCatalogException on a timeout', () async {
    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    serverSub = fakeServer.listen((client) {
      // Accept but never reply.
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);

    await expectLater(
      conn.fetchObject(topicRoutes, _routeUuid, timeout: const Duration(milliseconds: 200)),
      throwsA(isA<RouteCatalogException>()),
    );
  });

  test('addOrUpdateWaypoint matches a real captured tDeleteEntry-shaped ADD message structurally', () async {
    // **Resolved 2026-08-12** — see addOrUpdateWaypoint's own doc comment:
    // real captures of successful creates show `prevRemoteVer` is simply
    // "whatever remote_ver this connection most recently learned for the
    // topic", which this method now gets by always running a fresh
    // tCatalogSync (no merge-priming batch download) immediately before
    // building the message. This test rebuilds the "0005" message with
    // the same uuid/vstamp/name/coordinates, has the fake server answer
    // that sync with [_fakeRemoteVer], then checks every structural field
    // against the real captured bytes and that prevRemoteVer matches the
    // synced value.
    final capturedRest = _hexToBytes(
      'fa01f04dd432f4020000d4f0d5c9f5020000e8010107e40101e10105071110'
      'f34fe4371e0a4fb886b1e07788826a820dc99deeca251102190127c0010201'
      '000fba01b8011f8b08000000000004034d8edb0a83301044fb2dfb1c615773'
      '59f333126ba482b9a05128a5ffde4829f46d663833cc0b8e6399c0c2dcc9d9'
      'cbce34e4d135721eb9613d52e3d118666eb5e31604e42d95349c7e03db0a08'
      '4b1cfe1212b0ba02562b85a6d746559f2258226da86fb936a63daf43cae54a'
      'fb6a7d2e0fb0f1585701c587fcd3a12cc15f4da53a369d9202cebdb80b2044'
      'ee090dc9ba1fdd850122aafaee9e42f0b13ef80eeecf50717edf3e34844bf6'
      'e6000000',
    );
    final expected = _decodeAddOrUpdateStructure(capturedRest);

    late StreamSubscription<Socket> serverSub;
    final fakeServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Uint8List? sentRest;

    serverSub = fakeServer.listen((client) {
      final buf = BytesBuilder(copy: false);

      client.listen((chunk) {
        buf.add(chunk);
        var bytes = buf.toBytes();
        while (bytes.length >= 8) {
          final length = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
          if (bytes.length < 8 + length) break;
          final request = bytes.sublist(8, 8 + length);
          bytes = bytes.sublist(8 + length);
          if (request.length < 6) continue;
          final topicId = ByteData.sublistView(request, 0, 4).getUint32(0, Endian.little);
          final msgType = ByteData.sublistView(request, 4, 6).getUint16(0, Endian.little);
          if (msgType == 0x07) continue;

          if (msgType == tRegisterTopic) {
            final replyInner = Uint8List(6 + 8);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tRegisterTopicReply, Endian.little);
            replyInner[6] = 8;
            client.add(_wrapMsgFrame(replyInner));
            continue;
          } else if (msgType == tCatalogSync) {
            // addOrUpdateWaypoint now always syncs first to get a current
            // remote_ver -- see this test's own doc comment. _syncCatalog
            // requires (via _awaitCatalogSyncReply) the reply's own
            // correlation id at prefixLen(1) + 1 = offset 2 to match the
            // request's, and separately reads remote_ver at offset 18
            // (prefixLen + 1 + 16) -- both confirmed against a real
            // captured reply's own bytes, not just this file's other
            // fixtures (an earlier version of this fixture omitted the
            // correlation id and copied a different remote_ver offset (26)
            // used elsewhere in this file for a differently-shaped reply,
            // which made _awaitCatalogSyncReply never match and time out).
            final requestRest = request.sublist(6);
            final requestCorrelationId = requestRest.sublist(1, 9);
            final replyRest = Uint8List(18 + 8)
              ..setRange(2, 10, requestCorrelationId)
              ..setRange(18, 26, _fakeRemoteVer);
            final replyInner = Uint8List(6 + replyRest.length);
            ByteData.view(replyInner.buffer).setUint32(0, topicId, Endian.little);
            ByteData.view(replyInner.buffer).setUint16(4, tCatalogSyncReply, Endian.little);
            replyInner.setRange(6, 6 + replyRest.length, replyRest);
            client.add(_wrapMsgFrame(replyInner));
            continue;
          } else if (msgType == tDeleteEntry) {
            sentRest = Uint8List.sublistView(request, 6);
          }
        }
        buf.clear();
        buf.add(bytes);
      });
    });
    addTearDown(() async {
      await serverSub.cancel();
      await fakeServer.close();
    });

    RouteCatalogConnection.debugTrace = true;
    final conn = await RouteCatalogConnection.connect(
      InternetAddress.loopbackIPv4.address,
      port: fakeServer.port,
      timeout: const Duration(seconds: 2),
    );
    addTearDown(conn.close);
    addTearDown(() => RouteCatalogConnection.debugTrace = false);

    await conn.addOrUpdateWaypoint(
      '0005',
      655079675 * 180.0 / 2147483648.0,
      116719282 * 180.0 / 2147483648.0,
      uuid: 'f34fe437-1e0a-4fb8-86b1-e07788826a82',
      timeout: const Duration(seconds: 2),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sentRest, isNotNull, reason: 'the add/update message must have been sent');
    final actual = _decodeAddOrUpdateStructure(sentRest!);

    final actualPrevRemoteVer = Uint8List.sublistView(sentRest!, _leb128Length(sentRest!, 0), _leb128Length(sentRest!, 0) + 8);
    expect(actualPrevRemoteVer, _fakeRemoteVer, reason: 'prevRemoteVer must come from the fresh tCatalogSync, not a stale correlation id');

    expect(actual.fieldCount, expected.fieldCount);
    expect(actual.uuidMarker, expected.uuidMarker);
    expect(actual.uuid, expected.uuid);
    expect(actual.vstampTagByte, expected.vstampTagByte);
    expect(actual.protoVerTagByte, expected.protoVerTagByte);
    expect(actual.protoVer, expected.protoVer);
    expect(actual.minProtoVerTagByte, expected.minProtoVerTagByte);
    expect(actual.minProtoVer, expected.minProtoVer);
    expect(actual.wptDataTagByte, expected.wptDataTagByte);
    expect(actual.memberLengthMarker, expected.memberLengthMarker);
    // self-referential A/B relationship, not equality with the real
    // capture's own values (this message's newRemoteVer has a freshly
    // randomized `sub` half, which shifts the LEB128 width these offsets
    // depend on) -- see addOrUpdateWaypoint's doc comment.
    expect(actual.bLebLen + 1, actual.a - actual.b);
    // vstamp itself is freshly randomized per call (seq=2 fixed, sub
    // random -- see addOrUpdateWaypoint's doc comment), so only seq is
    // checked against the real capture, not the exact value.
    expect(actual.vstamp >> 32, expected.vstamp >> 32);
    expect(actual.json['uuid'], expected.json['uuid']);
    expect(actual.json['lat'], expected.json['lat']);
    expect(actual.json['lon'], expected.json['lon']);
    expect(actual.json['name'], expected.json['name']);
    // The full real field set -- corrected 2026-08-11 after a live create
    // with only the "obvious" fields sent successfully but didn't
    // actually appear in the catalog. dspl_optn/sym are constant across
    // every real create capture examined; depth/temp/comment are always
    // null; mtime is a fresh timestamp so only its presence is checked.
    expect(actual.json['dspl_optn'], expected.json['dspl_optn']);
    expect(actual.json['depth'], isNull);
    expect(actual.json['temp'], isNull);
    expect(actual.json['comment'], isNull);
    expect(actual.json['sym'], expected.json['sym']);
    expect(actual.json['mtime'], isNotNull);
  });
}

/// Decoded structural fields of an [RouteCatalogConnection.addOrUpdateWaypoint]
/// wire message, extracted anchor-by-anchor (not a fixed byte offset) so
/// this test can compare a real captured message against a freshly-sent
/// one whose `newRemoteVer`/self-referential length fields necessarily
/// differ byte-for-byte even when every meaningful field matches -- see
/// addOrUpdateWaypoint's own doc comment for the full field derivation.
class _AddOrUpdateStructure {
  final int a;
  final int b;
  final int bLebLen;
  final int fieldCount;
  final Uint8List uuidMarker;
  final Uint8List uuid;
  final int vstampTagByte;
  final int vstamp;
  final int protoVerTagByte;
  final int protoVer;
  final int minProtoVerTagByte;
  final int minProtoVer;
  final int wptDataTagByte;
  final Uint8List memberLengthMarker;
  final Map<String, dynamic> json;

  const _AddOrUpdateStructure({
    required this.a,
    required this.b,
    required this.bLebLen,
    required this.fieldCount,
    required this.uuidMarker,
    required this.uuid,
    required this.vstampTagByte,
    required this.vstamp,
    required this.protoVerTagByte,
    required this.protoVer,
    required this.minProtoVerTagByte,
    required this.minProtoVer,
    required this.wptDataTagByte,
    required this.memberLengthMarker,
    required this.json,
  });
}

/// Decodes the field-by-field structure of an add/update wire message —
/// see [RouteCatalogConnection.addOrUpdateWaypoint]'s own doc comment for
/// the full derivation. Every field is individually tagged
/// `(fieldId << 3) | lebLen` (0-indexed on the wire): uuid=`07`(fieldId 0,
/// overflow-length shape), vstamp=`0d`(fieldId 1), proto_ver=`11`(fieldId
/// 2), min_proto_ver=`19`(fieldId 3), wpt_data=`27`(fieldId 4,
/// overflow-length shape wrapping the gzip blob via the same
/// `02 01 00 0f` marker the download side already uses).
_AddOrUpdateStructure _decodeAddOrUpdateStructure(Uint8List rest) {
  var off = _leb128Length(rest, 0);
  off += 8; // prevRemoteVer
  off += 8; // newRemoteVer
  final tailLenLen = _leb128Length(rest, off);
  off += tailLenLen;
  final tail = Uint8List.sublistView(rest, off);

  var o = 2; // fixed 01 07
  final aLen = _leb128Length(tail, o);
  final a = _leb128Value(tail, o);
  o += aLen;
  // **Bug found 2026-08-12**: this byte was long assumed to be a fixed
  // `0x02` (mirrored from deleteEntry's own, differently-shaped `03`
  // marker) but every real captured create frame examined has `0x01`
  // here -- this decoder now asserts it explicitly instead of silently
  // skipping over it, so a regression back to the wrong value fails
  // loudly instead of passing structurally while being byte-wrong.
  if (tail[o] != 0x01) {
    throw StateError('expected marker byte 0x01 at offset $o, got 0x${tail[o].toRadixString(16)}');
  }
  o += 1;
  final bLen = _leb128Length(tail, o);
  final b = _leb128Value(tail, o);
  o += bLen;
  final fieldCountLen = _leb128Length(tail, o);
  final fieldCount = _leb128Value(tail, o);
  o += fieldCountLen;
  final uuidMarker = Uint8List.fromList(tail.sublist(o, o + 3));
  o += 3;
  final uuid = Uint8List.fromList(tail.sublist(o, o + 16));
  o += 16;
  final vstampTagByte = tail[o];
  final vstampLen = _leb128Length(tail, o + 1);
  final vstamp = _leb128Value(tail, o + 1);
  o += 1 + vstampLen;
  final protoVerTagByte = tail[o];
  final protoVerLen = _leb128Length(tail, o + 1);
  final protoVer = _leb128Value(tail, o + 1);
  o += 1 + protoVerLen;
  final minProtoVerTagByte = tail[o];
  final minProtoVerLen = _leb128Length(tail, o + 1);
  final minProtoVer = _leb128Value(tail, o + 1);
  o += 1 + minProtoVerLen;
  final wptDataTagByte = tail[o];
  o += 1;
  o += _leb128Length(tail, o); // wpt_data overflow-length (gzLen+8)
  final memberLengthMarker = Uint8List.fromList(tail.sublist(o, o + 4));
  o += 4;
  o += _leb128Length(tail, o); // gzLen+2
  final gzLenLen = _leb128Length(tail, o);
  final gzLen = _leb128Value(tail, o);
  o += gzLenLen;
  final gzBlob = tail.sublist(o, o + gzLen);
  var decompressed = GZipCodec().decode(gzBlob);
  var end = decompressed.length;
  while (end > 0 && decompressed[end - 1] == 0) {
    end--;
  }
  final json = jsonDecode(utf8.decode(decompressed.sublist(0, end))) as Map<String, dynamic>;

  return _AddOrUpdateStructure(
    a: a,
    b: b,
    bLebLen: bLen,
    fieldCount: fieldCount,
    uuidMarker: uuidMarker,
    uuid: uuid,
    vstampTagByte: vstampTagByte,
    vstamp: vstamp,
    protoVerTagByte: protoVerTagByte,
    protoVer: protoVer,
    minProtoVerTagByte: minProtoVerTagByte,
    minProtoVer: minProtoVer,
    wptDataTagByte: wptDataTagByte,
    memberLengthMarker: memberLengthMarker,
    json: json,
  );
}
