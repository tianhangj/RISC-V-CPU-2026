module axi_case;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    wire [31:0] araddr, awaddr, wdata;
    wire arvalid, arready, rready, awvalid, wvalid, bready;
    wire [3:0] wstrb;
    logic [31:0] rdata;
    logic rvalid;
    logic bvalid = 0;
    logic [7:0] memory [0:65535];
    logic [7:0] stack_memory [0:65535];
    reg [1023:0] image_path;
    integer expected, max_cycles;
    integer cycles = 0;
    integer read_head = 0, read_tail = 0, read_count = 0;
    logic [31:0] read_addr [0:31];
    integer read_due [0:31];
    logic aw_seen = 0, w_seen = 0;
    logic [31:0] aw_value, w_value;
    logic [3:0] strobe_value;
    integer b_due = 0;
    student_top dut (
        .clock, .reset, .araddr, .arvalid, .arready,
        .rdata, .rresp(2'b0), .rvalid, .rready,
        .awaddr, .awvalid, .awready(1'b1),
        .wdata, .wstrb, .wvalid, .wready(1'b1),
        .bresp(2'b0), .bvalid, .bready
    );
    assign arready = read_count < 16;
    assign rvalid = read_count > 0 && cycles >= read_due[read_head];
    function automatic [7:0] byte_at(input [31:0] address);
        if (address < 65536) byte_at = memory[address[15:0]];
        else if (address >= 32'h00030000 && address < 32'h00040000)
            byte_at = stack_memory[address[15:0]];
        else byte_at = 0;
    endfunction
    always @* begin
        rdata = 0;
        if (read_count > 0)
            rdata = {byte_at(read_addr[read_head]+3), byte_at(read_addr[read_head]+2),
                     byte_at(read_addr[read_head]+1), byte_at(read_addr[read_head])};
    end
    initial begin
        if (!$value$plusargs("image=%s", image_path)) $fatal(1, "missing +image");
        if (!$value$plusargs("expect=%d", expected)) $fatal(1, "missing +expect");
        if (!$value$plusargs("limit=%d", max_cycles)) max_cycles = 100000;
        for (int i = 0; i < 65536; i = i + 1) begin memory[i] = 0; stack_memory[i] = 0; end
        $readmemh(image_path, memory);
        repeat (5) @(posedge clock);
        @(negedge clock) reset = 0;
    end
    always @(posedge clock) begin
        if (!reset) begin
            cycles <= cycles + 1;
            if (cycles >= max_cycles) $fatal(1, "cycle limit reached");
            if (rvalid && rready) read_head <= (read_head + 1) % 32;
            if (arvalid && arready) begin
                read_addr[read_tail] <= araddr;
                read_due[read_tail] <= cycles + 3;
                read_tail <= (read_tail + 1) % 32;
            end
            read_count <= read_count + (arvalid && arready) - (rvalid && rready);
            if (awvalid) begin aw_seen <= 1; aw_value <= awaddr; end
            if (wvalid) begin w_seen <= 1; w_value <= wdata; strobe_value <= wstrb; end
            if (aw_seen && w_seen && !bvalid && cycles >= b_due) begin
                bvalid <= 1;
            end
            if (aw_seen && w_seen && b_due == 0) b_due <= cycles + 3;
            if (bvalid && bready) begin
                bvalid <= 0;
                aw_seen <= 0;
                w_seen <= 0;
                b_due <= 0;
                if (aw_value == 32'h80000000 && strobe_value == 4'hf) begin
                    if (w_value !== expected[31:0])
                        $fatal(1, "exit value got=%0d expected=%0d", w_value, expected);
                    $display("PASS cycles=%0d result=%0d", cycles, w_value);
                    $finish;
                end else if (aw_value < 65536) begin
                    for (int byte_no = 0; byte_no < 4; byte_no = byte_no + 1)
                        if (strobe_value[byte_no]) memory[aw_value+byte_no] <= w_value[8*byte_no +: 8];
                end else if (aw_value >= 32'h00030000 && aw_value < 32'h00040000) begin
                    for (int byte_no = 0; byte_no < 4; byte_no = byte_no + 1)
                        if (strobe_value[byte_no]) stack_memory[(aw_value+byte_no) & 16'hffff] <= w_value[8*byte_no +: 8];
                end
            end
        end
    end
endmodule
