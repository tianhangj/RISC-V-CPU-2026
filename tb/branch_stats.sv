module branch_stats_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [3:0] event_valid = 0;
    logic [4*103-1:0] resolve_payload = 0;
    logic [31:0] predicted_npc [0:3];
    branch_stats_monitor #(.ISSUE_WIDTH(4), .RESOLVE_BITS(103)) dut (.*);
    task automatic event_at(input integer lane, input integer pc,
                            input logic conditional, input logic taken,
                            input integer actual, input integer predicted);
        resolve_payload[lane*103 +: 103] =
            {3'(lane), 2'(lane), 32'(pc), conditional, taken, 32'h100, 32'(actual)};
        predicted_npc[lane] = predicted;
    endtask
    initial begin
        // Verify reset drops old observations.
        @(negedge clock) reset = 0;
        event_valid = 1;
        event_at(0, 32'hdead, 1, 1, 0, 0);
        @(negedge clock) reset = 1;
        @(negedge clock) begin reset = 0; event_valid = 4'hf; end
        // Taken-to-fallthrough is correct by next-PC, regardless of direction.
        event_at(0, 16, 1, 1, 20, 20);
        // Same PC in multiple lanes must add both observations.
        event_at(1, 16, 1, 0, 20, 99);
        event_at(2, 32, 0, 1, 256, 256);
        event_at(3, 48, 1, 0, 52, 52);
        @(negedge clock) begin
            event_valid = 4'b0101;
            event_at(0, 16, 1, 1, 256, 20);
            event_at(1, 16, 1, 1, 256, 20); // invalid lane must not count
            event_at(2, 32, 0, 1, 512, 256); // jump target changed
        end
        @(negedge clock) event_valid = 0;
        repeat (2) @(negedge clock);
        $finish;
    end
endmodule
