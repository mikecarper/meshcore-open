import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'companion_board_catalog.dart';

/// Exact reviewed local MeshCore variant environments and upstream d929643.
/// No filename-generated combinations: role and casing are part of target ID.
/// Full release overlays deliberately use target ID zero and need separate
/// digest-checked capability provenance; zero is not a lookup wildcard.
class CompanionTargetCatalog {
  static int targetIdForEnvironment(String environment) => ByteData.sublistView(
    Uint8List.fromList(crypto.sha256.convert(utf8.encode(environment)).bytes),
  ).getUint32(0, Endian.little);

  static final _targets = _buildTargets();

  static Map<int, (String, String)> _buildTargets() {
    final result = <int, (String, String)>{};
    for (final environment in environments) {
      final match = RegExp(
        r'_(?:companion_radio|companion|comp_radio)_(ble|full)(?:_|$)',
        caseSensitive: false,
      ).firstMatch(environment)!;
      final id = targetIdForEnvironment(environment);
      if (result.containsKey(id)) {
        throw StateError(
          'Reviewed Companion target IDs collide. No image can be selected.',
        );
      }
      result[id] = (
        environment.substring(0, match.start),
        match.group(1)!.toLowerCase(),
      );
    }
    return Map.unmodifiable(result);
  }

  static String? profileFor(int targetId, CompanionBoardSpec board) {
    final entry = _targets[targetId];
    if (entry == null ||
        !board.assetPrefixes.any(
          (prefix) => prefix.toLowerCase() == entry.$1.toLowerCase(),
        )) {
      return null;
    }
    return entry.$2;
  }

  static const environments = <String>[
    'Ebyte_EoRa-S3_companion_radio_ble',
    'GAT562_30S_Mesh_Kit_companion_radio_ble',
    'GAT562_Mesh_Tracker_Pro_companion_radio_ble',
    'GAT562_Mesh_Watch13_companion_radio_ble',
    'Heltec_E213_companion_radio_ble',
    'Heltec_E290_companion_ble',
    'Heltec_T190_companion_radio_ble_',
    'Heltec_WSL3_companion_radio_ble',
    'Heltec_WSL3_companion_radio_ble_ps',
    'Heltec_Wireless_Paper_companion_radio_ble',
    'Heltec_Wireless_Paper_companion_radio_ble_ps',
    'Heltec_Wireless_Tracker_companion_radio_ble',
    'Heltec_Wireless_Tracker_companion_radio_ble_ps',
    'Heltec_ct62_companion_radio_ble',
    'Heltec_ct62_companion_radio_ble_ps',
    'Heltec_mesh_solar_companion_radio_ble',
    'Heltec_t096_companion_radio_ble',
    'Heltec_t096_companion_radio_ble_femoff',
    'Heltec_t096_companion_radio_ble_femon',
    'Heltec_t114_companion_radio_ble',
    'Heltec_t114_without_display_companion_radio_ble',
    'Heltec_t1_companion_radio_ble',
    'Heltec_tower_v2_companion_radio_ble',
    'Heltec_v2_companion_radio_ble',
    'Heltec_v2_companion_radio_ble_ps',
    'Heltec_v3_companion_radio_ble',
    'Heltec_v3_companion_radio_ble_ps',
    'Heltec_v3_companion_radio_full',
    'KeepteenLT1_companion_radio_ble',
    'LilyGo_T-Echo-Lite_companion_radio_ble',
    'LilyGo_T-Echo-Lite_non_shell_companion_radio_ble',
    'LilyGo_T-Echo_Card_companion_radio_ble',
    'LilyGo_T-Echo_companion_radio_ble',
    'LilyGo_T3S3_sx1262_companion_radio_ble',
    'LilyGo_T3S3_sx1262_companion_radio_ble_ps',
    'LilyGo_T3S3_sx1276_companion_radio_ble',
    'LilyGo_TBeam_1W_companion_radio_ble',
    'LilyGo_TBeam_1W_companion_radio_ble_ps',
    'LilyGo_TBeam_1W_companion_radio_full',
    'LilyGo_TDeck_companion_radio_ble',
    'LilyGo_TETH_Elite_sx1262_companion_radio_ble',
    'LilyGo_TLora_V2_1_1_6_companion_radio_ble',
    'LilyGo_TLora_V2_1_1_6_companion_radio_ble_ps',
    'LilyGo_T_Impulse_Plus_companion_radio_ble',
    'LilyGo_Tlora_C6_companion_radio_ble_',
    'M5Stack_Unit_C6L_companion_radio_ble',
    'MKE_s3_companion_radio_ble',
    'MeshTracker_X1_companion_radio_ble',
    'Mesh_pocket_companion_radio_ble',
    'Meshadventurer_sx1262_companion_radio_ble',
    'Meshadventurer_sx1268_companion_radio_ble',
    'Meshimi_companion_radio_ble_',
    'Meshtiny_companion_radio_ble',
    'Minewsemi_me25ls01_companion_radio_ble',
    'Nano_G2_Ultra_companion_radio_ble',
    'PicoW_companion_radio_ble',
    'ProMicro_companion_radio_ble',
    'R1Neo_companion_radio_ble',
    'RAK_3112_companion_radio_ble',
    'RAK_3112_companion_radio_full',
    'RAK_3401_companion_radio_ble',
    'RAK_4631_companion_radio_ble',
    'RAK_4631_companion_radio_full',
    'RAK_WisMesh_Tag_companion_radio_ble',
    'SenseCap_Solar_companion_radio_ble',
    'Station_G2_companion_radio_ble',
    'Station_G2_companion_radio_full',
    'Station_G3_ESP32_companion_radio_ble',
    'Station_G3_ESP32_companion_radio_full',
    'T_Beam_S3_Supreme_SX1262_companion_radio_ble',
    'T_Beam_S3_Supreme_SX1262_companion_radio_ble_ps',
    'Tbeam_SX1262_companion_radio_ble',
    'Tbeam_SX1262_companion_radio_ble_ps',
    'Tbeam_SX1276_companion_radio_ble',
    'Tbeam_SX1276_companion_radio_ble_ps',
    'ThinkNode_M1_companion_radio_ble',
    'ThinkNode_M2_companion_radio_ble',
    'ThinkNode_M2_companion_radio_full',
    'ThinkNode_M3_companion_radio_ble',
    'ThinkNode_M4_companion_radio_ble',
    'ThinkNode_M5_companion_radio_ble',
    'ThinkNode_M5_companion_radio_ble_ps',
    'ThinkNode_M5_companion_radio_full',
    'ThinkNode_M6_companion_radio_ble',
    'ThinkNode_M7_companion_radio_ble',
    'ThinkNode_M7_companion_radio_full',
    'ThinkNode_M8_companion_radio_ble',
    'ThinkNode_M9_companion_radio_ble_',
    'WHY2025_badge_companion_radio_ble_',
    'WioTrackerL1-1W_companion_radio_ble',
    'WioTrackerL1Eink_companion_radio_ble',
    'WioTrackerL1_companion_radio_ble',
    'Xiao_C3_companion_radio_ble',
    'Xiao_C3_companion_radio_ble_ps',
    'Xiao_C6_companion_radio_ble_',
    'Xiao_S3_WIO_companion_radio_ble',
    'Xiao_S3_WIO_companion_radio_ble_ps',
    'Xiao_S3_WIO_companion_radio_full',
    'Xiao_S3_companion_radio_ble',
    'Xiao_S3_companion_radio_ble_ps',
    'Xiao_nrf52_companion_radio_ble',
    'heltec_rc32_companion_radio_ble',
    'heltec_rc32_companion_radio_full',
    'heltec_rc32_without_display_companion_radio_ble',
    'heltec_rc32_without_display_companion_radio_full',
    'heltec_tracker_v2_companion_radio_ble',
    'heltec_tracker_v2_companion_radio_ble_femoff',
    'heltec_tracker_v2_companion_radio_ble_femon',
    'heltec_tracker_v2_companion_radio_full_femon',
    'heltec_v4_2_v4_3_companion_radio_full_femon',
    'heltec_v4_3_companion_radio_ble_femoff',
    'heltec_v4_3_companion_radio_ble_ps_femoff',
    'heltec_v4_3_companion_radio_full_femoff',
    'heltec_v4_3_expansionkit_tft_companion_radio_ble_femoff',
    'heltec_v4_3_tft_companion_radio_ble_femoff',
    'heltec_v4_3_tft_companion_radio_full_femoff',
    'heltec_v4_companion_radio_ble',
    'heltec_v4_companion_radio_ble_femon',
    'heltec_v4_companion_radio_ble_ps_femon',
    'heltec_v4_expansionkit_tft_companion_radio_ble_femon',
    'heltec_v4_expansionkit_tft_companion_radio_ble_ps',
    'heltec_v4_expansionkit_tft_companion_radio_full_femon',
    'heltec_v4_r8_companion_radio_ble',
    'heltec_v4_r8_companion_radio_ble_ps',
    'heltec_v4_r8_companion_radio_full',
    'heltec_v4_r8_tft_companion_radio_ble',
    'heltec_v4_r8_tft_companion_radio_full',
    'heltec_v4_tft_companion_radio_ble',
    'heltec_v4_tft_companion_radio_ble_femon',
    'heltec_v4_tft_companion_radio_full_femon',
    'ikoka_handheld_nrf_e22_30dbm_096_companion_radio_ble',
    'ikoka_handheld_nrf_e22_30dbm_096_rotated_companion_radio_ble',
    'ikoka_nano_nrf_22dbm_companion_radio_ble',
    'ikoka_nano_nrf_30dbm_companion_radio_ble',
    'ikoka_nano_nrf_33dbm_companion_radio_ble',
    'ikoka_stick_nrf_22dbm_companion_radio_ble',
    'ikoka_stick_nrf_30dbm_companion_radio_ble',
    'ikoka_stick_nrf_33dbm_companion_radio_ble',
    'meshnology_w12_companion_radio_ble',
    'meshnology_w12_companion_radio_full',
    'muzi_base_duo_companion_radio_ble',
    'muzi_base_duo_superIO_companion_radio_ble',
    'muzi_base_uno_companion_radio_ble',
    'muzi_base_uno_superIO_companion_radio_ble',
    'nibble_screen_connect_companion_radio_ble_',
    'nibble_screen_connect_companion_radio_full_',
    'nibble_zero_connect_companion_radio_ble_',
    'nibble_zero_connect_companion_radio_full_',
    'solarxiao_30S_companion_radio_ble',
    'solarxiao_33S_companion_radio_ble',
    't1000e_companion_radio_ble',
    'wio_wm1110_companion_radio_ble',
  ];
}
