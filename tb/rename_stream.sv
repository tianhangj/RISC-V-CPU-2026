module rename_stream_case #(parameter integer D = 1)(output logic done);
    localparam integer DCW = $clog2(D+1);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0, decode_valid = 0, disp_ready = 0;
    logic [D*117-1:0] decode_uop = 0;
    logic [5:0] rob_free = 32;
    logic [4:0] rob_tail = 0;
    logic [4:0] alu_iq_free = 16, mem_iq_free = 16;
    wire decode_ready, disp_valid, front_redirect_valid;
    wire [DCW-1:0] disp_count;
    wire [D*95-1:0] disp_alu;
    wire [D-1:0] disp_src1_ready;
    integer dispatched = 0, cycle = 0, last_dispatch = -1;
    logic measure = 0;
    logic [D*95-1:0] held;

    rename #(.DISPATCH_WIDTH(D), .WB_WIDTH(1), .COMMIT_WIDTH(1)) dut (
        .clock, .reset, .squash_valid, .restore_cp_id(2'd0), .cp_release_mask(4'd0),
        .cp_free(3'd4), .cp_alloc_id({D{2'd0}}),
        .decode_valid, .decode_ready, .decode_count(DCW'(D)), .decode_uop,
        .rob_free, .rob_tail, .alu_iq_free, .mem_iq_free,
        .lq_free(4'd8), .sq_free(4'd8), .lq_alloc_id({D{3'd0}}), .sq_alloc_id({D{3'd0}}),
        .disp_valid, .disp_ready, .disp_count, .disp_alu, .disp_src1_ready,
        .front_redirect_valid, .wake_valid(1'b0), .wake_pdst(6'd0),
        .reg_commit_valid(1'b0), .reg_commit_payload(6'd0)
    );

    function automatic [116:0] uop(input [31:0] pc, npc);
        // Every instruction reads and rewrites x1, including across packets.
        uop = {pc, npc, 6'd11, 5'd1, 5'd0, 5'd1, 32'd1};
    endfunction
    task automatic tick;
        @(posedge clock);
        #1;
    endtask
    task automatic restart;
        @(negedge clock);
        reset = 1;
        decode_valid = 0;
        disp_ready = 0;
        squash_valid = 0;
        rob_free = 32;
        alu_iq_free = 16;
        mem_iq_free = 16;
        measure = 0;
        tick();
        @(negedge clock) reset = 0;
    endtask

    always @(posedge clock) begin
        if (reset) begin
            dispatched = 0;
            cycle = 0;
            last_dispatch = -1;
            rob_tail <= 0;
        end else begin
            cycle = cycle + 1;
            if (disp_valid && disp_ready) begin
                if (measure) begin
                    if (last_dispatch >= 0 && cycle-last_dispatch != 2)
                        $fatal(1, "D=%0d streaming dispatch took %0d cycles", D, cycle-last_dispatch);
                    last_dispatch = cycle;
                    for (integer lane = 0; lane < D; lane = lane+1) begin
                        if (disp_alu[lane*95+64+6 +: 6] !==
                            6'((dispatched == 0 && lane == 0) ? 1 : 31+dispatched+lane) ||
                            disp_alu[lane*95+64+12 +: 6] !== 6'(32+dispatched+lane) ||
                            disp_alu[lane*95+90 +: 5] !== 5'(dispatched+lane))
                            $fatal(1, "D=%0d lane=%0d lost cross-packet RAT/ROB state", D, lane);
                        if (disp_src1_ready[lane] !== (dispatched == 0 && lane == 0))
                            $fatal(1, "D=%0d lane=%0d incorrect RAW readiness", D, lane);
                    end
                end
                dispatched = dispatched + int'(disp_count);
                rob_tail <= rob_tail + 5'(disp_count);
            end
        end
    end

    initial begin
        done = 0;
        tick();
        restart();
        for (integer lane = 0; lane < D; lane = lane+1)
            decode_uop[lane*117 +: 117] = uop(32'(lane*4), 32'((lane+1)*4));
        decode_valid = 1;
        tick();
        @(negedge clock) decode_valid = 0;
        tick();
        if (!disp_valid || decode_ready) $fatal(1, "D=%0d held offer allowed overwrite", D);
        held = disp_alu;
        repeat (3) begin
            tick();
            if (!disp_valid || decode_ready || disp_alu !== held)
                $fatal(1, "D=%0d backpressure changed offer", D);
        end
        @(negedge clock);
        measure = 1;
        disp_ready = 1;
        decode_valid = 1;
        #1;
        if (!decode_ready) $fatal(1, "D=%0d complete dispatch did not accept successor", D);
        tick();
        while (dispatched < 5*D) tick();
        @(negedge clock) decode_valid = 0;
        while (dispatched < 6*D) tick();
        tick();
        if (disp_valid || !decode_ready) $fatal(1, "D=%0d successor packet lost or duplicated", D);

        // Preparing destinations while credits are zero must not consume them.
        // Reopening one credit publishes only the prefix and preserves RAWs.
        restart();
        alu_iq_free = 0;
        decode_valid = 1;
        tick();
        @(negedge clock) decode_valid = 0;
        repeat (3) tick();
        if (disp_valid) $fatal(1, "D=%0d zero queue credits admitted an offer", D);
        @(negedge clock) alu_iq_free = 1;
        tick();
        if (!disp_valid || disp_count != 1 ||
            disp_alu[64+12 +: 6] !== 6'd32 || disp_alu[64+6 +: 6] !== 6'd1)
            $fatal(1, "D=%0d credit stall consumed a prepared destination", D);
        held = disp_alu;
        @(negedge clock) alu_iq_free = 0;
        repeat (2) begin
            tick();
            if (!disp_valid || disp_alu !== held)
                $fatal(1, "D=%0d credit change overwrote a held offer", D);
        end
        @(negedge clock);
        alu_iq_free = 1;
        disp_ready = 1;
        tick();
        tick();
        if (D > 1 && (!disp_valid || disp_count != 1 ||
                      disp_alu[64+12 +: 6] !== 6'd33 || disp_alu[64+6 +: 6] !== 6'd32))
            $fatal(1, "D=%0d credit-limited suffix lost its destination or RAW", D);

        // A short offer retains its suffix and must not admit a successor.
        if (D > 1) begin
            restart();
            rob_free = 1;
            decode_valid = 1;
            tick();
            @(negedge clock) decode_valid = 0;
            tick();
            @(negedge clock) disp_ready = 1;
            #1;
            if (disp_count != 1 || decode_ready) $fatal(1, "D=%0d partial packet overwritten", D);
            tick();
            if (!dut.buf_valid || dut.buf_count != D-1)
                $fatal(1, "D=%0d partial packet suffix lost", D);
        end

        // Frontend correction and squash reject old-path input.
        restart();
        decode_uop[0 +: 117] = uop(32'd0, 32'd64);
        decode_valid = 1;
        tick();
        @(negedge clock) decode_valid = 0;
        tick();
        @(negedge clock) disp_ready = 1;
        #1;
        if (!front_redirect_valid || decode_ready)
            $fatal(1, "D=%0d frontend correction admitted old-path input", D);
        tick();
        restart();
        decode_uop[0 +: 117] = uop(32'd0, 32'd4);
        decode_valid = 1;
        tick();
        @(negedge clock) decode_valid = 0;
        tick();
        @(negedge clock);
        squash_valid = 1;
        disp_ready = 1;
        decode_valid = 1;
        #1;
        if (decode_ready || disp_valid) $fatal(1, "D=%0d squash admitted old-path input", D);
        tick();
        if (dut.buf_valid || dut.offer_valid) $fatal(1, "D=%0d squash kept frontend work", D);
        done = 1;
    end
endmodule

module rename_stream_test;
    wire done1, done2, done4;
    rename_stream_case #(.D(1)) one(done1);
    rename_stream_case #(.D(2)) two(done2);
    rename_stream_case #(.D(4)) four(done4);
    initial begin
        wait (done1 && done2 && done4);
        $display("rename streaming, RAW, backpressure, partial packet and redirect PASS");
        $finish;
    end
    initial begin
        #3000;
        $fatal(1, "rename stream timeout");
    end
endmodule
