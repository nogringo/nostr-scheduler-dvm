import 'package:ndk/ndk.dart';
import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:sembast/sembast.dart';
import 'package:sync_engine_shim_for_ndk/sync_engine_shim_for_ndk.dart';

Future<SchedulerDvm> startDedicatedDvm({
  required Ndk dvmNdk,
  required Database database,
  required SyncEngine syncEngine,
  required List<String> bootstrapRelays,
}) async {
  final dvm = SchedulerDvm(
    SchedulerDvmConfig(
      ndk: dvmNdk,
      store: SembastDvmJobStore(database),
      syncEngine: syncEngine,
      bootstrapRelays: bootstrapRelays,
    ),
  );

  await dvm.start();
  return dvm;
}

Future<SchedulerDvm> startEmbeddedDvm({
  required Ndk appNdk,
  required EventSigner signer,
  required Database database,
  required SyncEngine syncEngine,
  required List<String> bootstrapRelays,
}) async {
  final dvm = SchedulerDvm(
    SchedulerDvmConfig(
      ndk: appNdk,
      signer: signer,
      store: SembastDvmJobStore(database),
      syncEngine: syncEngine,
      bootstrapRelays: bootstrapRelays,
    ),
  );

  await dvm.start();
  return dvm;
}
