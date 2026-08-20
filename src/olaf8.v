`default_nettype none

// ============================================================
// OLAF-8
// Bounded-Memory Online Adaptive Fuzzy Inference Engine
//
// STEP 1 OPTIMIZATION:
// Sequential least-utility rule selection.
//
// The existing 8-cycle rule scan is reused to determine the
// least-utility rule. This removes the combinational 8-entry
// minimum-selection network.
//
// Tiny Tapeout interface:
//
// ui_in[7:4] : x1
// ui_in[3:0] : x2
// uio_in[0]  : start
//
// uo_out[3:0] : fuzzy output y
// uo_out[4]   : done
// uo_out[5]   : admitted/replaced
// uo_out[6]   : busy
// uo_out[7]   : reserved = 0
//
// ============================================================

module tt_um_olaf8 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire ena,
    input  wire clk,
    input  wire rst_n
);

    wire [3:0] y;
    wire       done;
    wire       admitted;
    wire       busy;

    olaf8_core core (
        .x1(ui_in[7:4]),
        .x2(ui_in[3:0]),
        .start(uio_in[0] & ena),
        .clk(clk),
        .rst_n(rst_n),
        .y(y),
        .done(done),
        .admitted(admitted),
        .busy(busy)
    );

    assign uo_out = {1'b0, busy, admitted, done, y};

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

endmodule


// ============================================================
// OLAF-8 CORE
// ============================================================

module olaf8_core (
    input  wire [3:0] x1,
    input  wire [3:0] x2,
    input  wire       start,
    input  wire       clk,
    input  wire       rst_n,

    output reg [3:0] y,
    output reg       done,
    output reg       admitted,
    output reg       busy
);

    // --------------------------------------------------------
    // Fixed OLAF-8 parameters
    // --------------------------------------------------------

    localparam [3:0] ADMIT_THRESHOLD = 4'd6;

    // Rules 0 through 7.
    localparam [2:0] N_RULES = 3'd7;


    // --------------------------------------------------------
    // Rule memory
    //
    // antecedent label:
    //   0 = LOW
    //   1 = MID
    //   2 = HIGH
    //
    // consequent:
    //   4-bit singleton output
    //
    // utility:
    //   3-bit saturating usage score
    // --------------------------------------------------------

    reg [1:0] rule_a1 [0:7];
    reg [1:0] rule_a2 [0:7];
    reg [3:0] rule_y  [0:7];
    reg [2:0] rule_u  [0:7];


    // --------------------------------------------------------
    // Captured input
    // --------------------------------------------------------

    reg [3:0] x1_r;
    reg [3:0] x2_r;


    // --------------------------------------------------------
    // Rule scan state
    // --------------------------------------------------------

    reg [2:0] rule_idx;

    // Maximum firing strength and corresponding rule.
    reg [3:0] max_fire;
    reg [2:0] max_idx;


    // --------------------------------------------------------
    // STEP 1 OPTIMIZATION
    //
    // Sequential least-utility search.
    //
    // These two registers replace the previous combinational
    // 8-rule minimum selector.
    // --------------------------------------------------------

    reg [2:0] min_util_r;
    reg [2:0] min_idx_r;


    // --------------------------------------------------------
    // Weighted accumulation
    // --------------------------------------------------------

    reg [10:0] sum_num;
    reg [6:0]  sum_den;


    // --------------------------------------------------------
    // Iterative restoring divider
    // --------------------------------------------------------

    reg [10:0] div_num;
    reg [7:0]  div_rem;
    reg [6:0]  div_den;
    reg [10:0] div_quot;
    reg [3:0]  div_count;


    // --------------------------------------------------------
    // FSM
    // --------------------------------------------------------

    reg [1:0] state;

    localparam S_IDLE = 2'd0;
    localparam S_SCAN = 2'd1;
    localparam S_DIV  = 2'd2;


    // ========================================================
    // MEMBERSHIP FUNCTION
    // ========================================================

    function [3:0] memb;

        input [3:0] x;
        input [1:0] label;

        reg [4:0] t;

        begin

            case (label)

                // ------------------------------------------------
                // LOW
                // ------------------------------------------------

                2'd0: begin

                    if (x <= 4'd7)
                        memb = 4'd15 - {x[2:0],1'b0};
                    else
                        memb = 4'd0;

                end


                // ------------------------------------------------
                // MID
                // ------------------------------------------------

                2'd1: begin

                    if (x <= 4'd7)

                        memb = {x[2:0],1'b0};

                    else begin

                        t = 5'd30 - {1'b0,x,1'b0};

                        memb = (t[4]) ?
                               4'd0 :
                               t[3:0];

                    end

                end


                // ------------------------------------------------
                // HIGH
                // ------------------------------------------------

                default: begin

                    if (x < 4'd8)

                        memb = 4'd0;

                    else begin

                        t = {1'b0,x} - 5'd7;
                        t = {t[3:0],1'b0};

                        memb = (t > 5'd15) ?
                               4'd15 :
                               t[3:0];

                    end

                end

            endcase

        end

    endfunction


    // ========================================================
    // PEAK MEMBERSHIP LABEL
    // ========================================================

    function [1:0] peak_label;

        input [3:0] x;

        begin

            if (x <= 4'd3)

                peak_label = 2'd0;

            else if (x <= 4'd11)

                peak_label = 2'd1;

            else

                peak_label = 2'd2;

        end

    endfunction


    // ========================================================
    // CURRENT RULE DATAPATH
    // ========================================================

    wire [3:0] cur_m1;
    wire [3:0] cur_m2;
    wire [3:0] cur_fire;
    wire [7:0] cur_prod;

    assign cur_m1 =
        memb(x1_r, rule_a1[rule_idx]);

    assign cur_m2 =
        memb(x2_r, rule_a2[rule_idx]);

    // MIN fuzzy firing strength.
    assign cur_fire =
        (cur_m1 < cur_m2) ?
        cur_m1 :
        cur_m2;

    // Firing strength × consequent.
    assign cur_prod =
        cur_fire * rule_y[rule_idx];


    // ========================================================
    // LAST RULE ACCUMULATION
    // ========================================================

    wire [10:0] last_sum_num;
    wire [6:0]  last_sum_den;

    assign last_sum_num =
        sum_num + cur_prod;

    assign last_sum_den =
        sum_den + cur_fire;


    // ========================================================
    // LAST RULE MAXIMUM FIRING VALUE
    // ========================================================

    wire [3:0] last_max_fire;
    wire [2:0] last_max_idx;

    assign last_max_fire =
        (cur_fire > max_fire) ?
        cur_fire :
        max_fire;

    assign last_max_idx =
        (cur_fire > max_fire) ?
        rule_idx :
        max_idx;


    // ========================================================
    // RESTORING DIVIDER NEXT STATE
    // ========================================================

    wire [7:0] rem_shift;
    wire       div_take;
    wire [7:0] rem_next;
    wire [10:0] quot_next;

    assign rem_shift =
        {div_rem[6:0], div_num[10]};

    assign div_take =
        (rem_shift >= {1'b0, div_den});

    assign rem_next =
        div_take ?
        (rem_shift - {1'b0, div_den}) :
        rem_shift;

    assign quot_next =
        {div_quot[9:0], div_take};


    // ========================================================
    // MAIN SEQUENTIAL PROCESS
    // ========================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            // ------------------------------------------------
            // Control
            // ------------------------------------------------

            state    <= S_IDLE;

            y        <= 4'd8;
            done     <= 1'b0;
            admitted <= 1'b0;
            busy     <= 1'b0;


            // ------------------------------------------------
            // Input state
            // ------------------------------------------------

            x1_r <= 4'd0;
            x2_r <= 4'd0;


            // ------------------------------------------------
            // Rule scan state
            // ------------------------------------------------

            rule_idx <= 3'd0;

            max_fire <= 4'd0;
            max_idx  <= 3'd0;


            // ------------------------------------------------
            // STEP 1:
            // Minimum utility search state.
            // ------------------------------------------------

            min_util_r <= 3'd7;
            min_idx_r  <= 3'd0;


            // ------------------------------------------------
            // Accumulators
            // ------------------------------------------------

            sum_num <= 11'd0;
            sum_den <= 7'd0;


            // ------------------------------------------------
            // Divider
            // ------------------------------------------------

            div_num   <= 11'd0;
            div_rem   <= 8'd0;
            div_den   <= 7'd0;
            div_quot  <= 11'd0;
            div_count <= 4'd0;


            // ------------------------------------------------
            // Initial rule base
            // ------------------------------------------------

            rule_a1[0] <= 2'd0;
            rule_a2[0] <= 2'd0;
            rule_y [0] <= 4'd2;
            rule_u [0] <= 3'd1;

            rule_a1[1] <= 2'd0;
            rule_a2[1] <= 2'd1;
            rule_y [1] <= 4'd5;
            rule_u [1] <= 3'd1;

            rule_a1[2] <= 2'd0;
            rule_a2[2] <= 2'd2;
            rule_y [2] <= 4'd7;
            rule_u [2] <= 3'd1;

            rule_a1[3] <= 2'd1;
            rule_a2[3] <= 2'd0;
            rule_y [3] <= 4'd5;
            rule_u [3] <= 3'd1;

            rule_a1[4] <= 2'd1;
            rule_a2[4] <= 2'd1;
            rule_y [4] <= 4'd8;
            rule_u [4] <= 3'd1;

            rule_a1[5] <= 2'd1;
            rule_a2[5] <= 2'd2;
            rule_y [5] <= 4'd10;
            rule_u [5] <= 3'd1;

            rule_a1[6] <= 2'd2;
            rule_a2[6] <= 2'd0;
            rule_y [6] <= 4'd7;
            rule_u [6] <= 3'd1;

            rule_a1[7] <= 2'd2;
            rule_a2[7] <= 2'd2;
            rule_y [7] <= 4'd13;
            rule_u [7] <= 3'd1;

        end

        else begin

            // ------------------------------------------------
            // One-cycle status pulses
            // ------------------------------------------------

            done     <= 1'b0;
            admitted <= 1'b0;


            case (state)


                // ====================================================
                // IDLE
                // ====================================================

                S_IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        // Capture input sample.
                        x1_r <= x1;
                        x2_r <= x2;

                        // Start rule scan.
                        rule_idx <= 3'd0;

                        // Clear maximum firing search.
                        max_fire <= 4'd0;
                        max_idx  <= 3'd0;

                        // Clear weighted accumulation.
                        sum_num <= 11'd0;
                        sum_den <= 7'd0;

                        // ------------------------------------------------
                        // STEP 1:
                        // Initialize least-utility search.
                        //
                        // Utility is 3 bits, so 7 is the maximum possible
                        // utility value. Rule 0 will establish the initial
                        // minimum during the first scan cycle.
                        // ------------------------------------------------

                        min_util_r <= 3'd7;
                        min_idx_r  <= 3'd0;

                        busy  <= 1'b1;
                        state <= S_SCAN;

                    end

                end


                // ====================================================
                // RULE SCAN
                // ====================================================

                S_SCAN: begin

                    busy <= 1'b1;


                    // ------------------------------------------------
                    // Existing fuzzy inference accumulation.
                    // ------------------------------------------------

                    sum_num <= sum_num + cur_prod;
                    sum_den <= sum_den + cur_fire;


                    // ------------------------------------------------
                    // Existing maximum firing-strength search.
                    // ------------------------------------------------

                    if (cur_fire > max_fire) begin

                        max_fire <= cur_fire;
                        max_idx  <= rule_idx;

                    end


                    // ------------------------------------------------
                    // STEP 1 OPTIMIZATION
                    //
                    // Sequential least-utility search.
                    //
                    // Instead of an always @* loop comparing all
                    // eight rule utilities simultaneously, the
                    // existing rule scan compares one utility per
                    // cycle.
                    //
                    // Strict '<' preserves the original tie behavior:
                    // the first rule with minimum utility is retained.
                    // ------------------------------------------------

                    if (rule_u[rule_idx] < min_util_r) begin

                        min_util_r <= rule_u[rule_idx];
                        min_idx_r  <= rule_idx;

                    end


                    // ------------------------------------------------
                    // Last rule of the 8-rule scan.
                    // ------------------------------------------------

                    if (rule_idx == N_RULES) begin

                        // Start restoring divider.
                        div_num <= last_sum_num;

                        div_den <=
                            (last_sum_den == 0) ?
                            7'd1 :
                            last_sum_den;

                        div_rem   <= 8'd0;
                        div_quot  <= 11'd0;
                        div_count <= 4'd0;

                        // Preserve final maximum firing result.
                        max_fire <= last_max_fire;
                        max_idx  <= last_max_idx;

                        state <= S_DIV;

                    end

                    else begin

                        rule_idx <= rule_idx + 3'd1;

                    end

                end


                // ====================================================
                // ITERATIVE DIVISION
                // ====================================================

                S_DIV: begin

                    busy <= 1'b1;

                    // One quotient bit per cycle.
                    div_rem  <= rem_next;
                    div_num  <= {div_num[9:0],1'b0};
                    div_quot <= quot_next;


                    if (div_count == 4'd10) begin

                        // ------------------------------------------------
                        // Saturate quotient to 4-bit output.
                        // ------------------------------------------------

                        if (div_quot[10:4] != 0)

                            y <= 4'd15;

                        else

                            y <= div_quot[3:0];


                        // ------------------------------------------------
                        // Firing-strength-gated online admission.
                        //
                        // UNCHANGED from baseline.
                        // ------------------------------------------------

                        if (max_fire < ADMIT_THRESHOLD) begin

                            // ------------------------------------------------
                            // STEP 1:
                            //
                            // min_idx_r contains the least-utility
                            // rule discovered during the scan.
                            // ------------------------------------------------

                            rule_a1[min_idx_r] <=
                                peak_label(x1_r);

                            rule_a2[min_idx_r] <=
                                peak_label(x2_r);


                            if (div_quot[10:4] != 0)

                                rule_y[min_idx_r] <= 4'd15;

                            else if ((div_quot[3:0] == 0) &&
                                     (sum_den == 0))

                                rule_y[min_idx_r] <= 4'd8;

                            else

                                rule_y[min_idx_r] <=
                                    div_quot[3:0];


                            // New rule receives utility 4.
                            rule_u[min_idx_r] <= 3'd4;

                            admitted <= 1'b1;

                        end

                        else begin

                            // ------------------------------------------------
                            // Existing winning-rule utility update.
                            // ------------------------------------------------

                            if (rule_u[max_idx] != 3'd7)

                                rule_u[max_idx] <=
                                    rule_u[max_idx] + 3'd1;

                        end


                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;

                    end

                    else begin

                        div_count <= div_count + 4'd1;

                    end

                end


                // ====================================================
                // DEFAULT
                // ====================================================

                default: begin

                    state <= S_IDLE;

                end

            endcase

        end

    end

endmodule


`default_nettype wire
