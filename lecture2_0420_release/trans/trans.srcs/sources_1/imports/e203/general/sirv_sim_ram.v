 /*                                                                      
 Copyright 2018-2020 Nuclei System Technology, Inc.                
                                                                         
 Licensed under the Apache License, Version 2.0 (the "License");         
 you may not use this file except in compliance with the License.        
 You may obtain a copy of the License at                                 
                                                                         
     http://www.apache.org/licenses/LICENSE-2.0                          
                                                                         
  Unless required by applicable law or agreed to in writing, software    
 distributed under the License is distributed on an "AS IS" BASIS,       
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and     
 limitations under the License.                                          
 */                                                                      
                                                                         
                                                                         
                                                                         
//=====================================================================
//
// Designer   : Bob Hu
//
// Description:
//  The simulation model of SRAM
//
// ====================================================================
module sirv_sim_ram 
#(parameter DP = 512,
  parameter FORCE_X2ZERO = 0,
  parameter INIT_HEX = 0,
  parameter DW = 32,
  parameter MW = 4,
  parameter AW = 32 
)
(
  input             clk, 
  input             rst,
  input  [DW-1  :0] din, 
  input  [AW-1  :0] addr,
  input             cs,
  input             we,
  input  [MW-1:0]   wem,
  output [DW-1:0]   dout
);

    (* ram_style = "block" *) reg [DW-1:0] mem_r [0:DP-1];
    reg [AW-1:0] addr_r;
    wire [MW-1:0] wen;
    wire ren;

    assign ren = cs & (~we);
    assign wen = ({MW{cs & we}} & wem);

    genvar i;
    integer j;
    integer k;

    initial begin
        for (k = 0; k < DP; k = k + 1) begin
            mem_r[k] = {DW{1'b0}};
        end
        if (INIT_HEX) begin
            $readmemh("D:/Desktop/cjt_grade3_xia/CS_APP/Project/Honor/lecture2_0420_release/hexdump-2.1.0/test2.hex", mem_r);
        end
    end

    always @(posedge clk) begin
        if (ren)
            addr_r <= addr;
        for (j = 0; j < MW; j = j + 1) begin
            if (wen[j])
                mem_r[addr][8*j +: 8] <= din[8*j +: 8];
        end
    end

  wire [DW-1:0] dout_pre;
  assign dout_pre = mem_r[addr_r];

  generate
   if(FORCE_X2ZERO == 1) begin: force_x_to_zero
      for (i = 0; i < DW; i = i+1) begin:force_x_gen
          `ifndef SYNTHESIS//{
         assign dout[i] = (dout_pre[i] === 1'bx) ? 1'b0 : dout_pre[i];
          `else//}{
         assign dout[i] = dout_pre[i];
          `endif//}
      end
   end
   else begin:no_force_x_to_zero
     assign dout = dout_pre;
   end
  endgenerate

 
endmodule
