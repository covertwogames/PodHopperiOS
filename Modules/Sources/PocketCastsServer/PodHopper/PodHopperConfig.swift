import Foundation

/// Configuration for PodHopper's Supabase backend.
///
/// Same project, anon key, and pull page size the Android client and the car use, so all three
/// platforms talk to the same backend. The backend itself (GoTrue auth, the subscriptions and
/// playback_state tables, and the pairing and delete-account edge functions) already exists; the
/// iOS side is a client port only.
enum PodHopperConfig {
    static let supabaseURL = "https://vamqoxkasykfhnlfeixz.supabase.co"
    static let supabaseAnonKey = "sb_publishable_mkv0y6AoTSkPoY6MekLj2g_ZOqpdKVv"
    static let pullPageLimit = 200
}
