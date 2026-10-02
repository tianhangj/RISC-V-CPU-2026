// Technology-independent buffers. The retained inverter boundaries let the
// mapper preserve a bounded-fanout distribution tree for wide control nets.
module signal_inverter #(parameter integer WIDTH = 1) (
    input wire [WIDTH-1:0] a,
    output wire [WIDTH-1:0] y
);
    assign y = ~a;
endmodule

module signal_buffer #(parameter integer WIDTH = 1) (
    input wire [WIDTH-1:0] a,
    output wire [WIDTH-1:0] y
);
    wire [WIDTH-1:0] inverted;
    (* keep_hierarchy, keep *) signal_inverter #(.WIDTH(WIDTH)) first(a, inverted);
    (* keep_hierarchy, keep *) signal_inverter #(.WIDTH(WIDTH)) second(inverted, y);
endmodule

module signal_fanout #(
    parameter integer WIDTH = 1,
    parameter integer BRANCHES = 1
) (
    input wire [WIDTH-1:0] a,
    output wire [BRANCHES*WIDTH-1:0] y
);
    generate if (BRANCHES <= 4) begin : g_leaf
        for (genvar branch = 0; branch < BRANCHES; branch = branch+1) begin : g_branch
            (* keep_hierarchy, keep *) signal_buffer #(.WIDTH(WIDTH)) buffer_cell(
                a, y[branch*WIDTH +: WIDTH]);
        end
    end else begin : g_tree
        localparam integer GROUP_SIZE = (BRANCHES+3)/4;
        localparam integer GROUP_COUNT = (BRANCHES+GROUP_SIZE-1)/GROUP_SIZE;
        for (genvar group_no = 0; group_no < GROUP_COUNT; group_no = group_no+1) begin : g_group
            localparam integer START = group_no*GROUP_SIZE;
            localparam integer COUNT = (BRANCHES-START < GROUP_SIZE) ?
                BRANCHES-START : GROUP_SIZE;
            wire [WIDTH-1:0] group_signal;
            (* keep_hierarchy, keep *) signal_buffer #(.WIDTH(WIDTH)) buffer_cell(a, group_signal);
            (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(WIDTH), .BRANCHES(COUNT)) subtree(
                group_signal, y[START*WIDTH +: COUNT*WIDTH]);
        end
    end endgenerate
endmodule
