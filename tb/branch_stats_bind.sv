bind branch_ctrl branch_stats_monitor #(
    .ISSUE_WIDTH(ISSUE_WIDTH), .CHECKPOINT_DEPTH(CHECKPOINT_DEPTH),
    .CIDW(CIDW), .RESOLVE_BITS(RESOLVE_BITS)
) u_stats (
    .clock(clock), .reset(reset), .event_valid(surviving),
    .resolve_payload(resolve_payload), .predicted_npc(cp_pred_npc)
);
