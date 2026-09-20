/// Which identity the DVM may reveal to a target relay that answers
/// `auth-required` (NIP-42).
///
/// Nothing is revealed to a relay that does not ask: the event always goes out
/// on the anonymous connection first, and only a refusal moves it to an
/// authenticated one.
enum TargetRelayAuth {
  /// A key generated for that publish alone, so a relay cannot tell that two
  /// scheduled events went through the same DVM.
  ///
  /// It only gets in on a relay that accepts an unknown pubkey. One that
  /// restricts writes to the people it knows refuses this key, as it would
  /// refuse the DVM's own.
  ephemeral,

  /// The DVM's own key, for a DVM its target relays already know.
  ///
  /// The relay then learns which events it published, and can tie together
  /// every client it publishes for.
  dvm,

  /// Never authenticate: the publish fails rather than name anyone.
  never,
}
