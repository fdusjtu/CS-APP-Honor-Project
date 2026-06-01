def format_hex(input_file, output_file):
    with open(input_file, 'r') as f_input, open(output_file, 'w') as f_output:
        hex_string = ''
        for line in f_input:
            hex_string += line.strip()
        # 分割成长度为16的子字符串并以换行符连接
        formatted_line = '\n'.join(hex_string[i+14:i+16]+hex_string[i+12:i+14]+hex_string[i+10:i+12]+hex_string[i+8:i+10]+hex_string[i+6:i+8]+hex_string[i+4:i+6]+hex_string[i+2:i+4]+hex_string[i:i+2] for i in range(0, len(hex_string), 16))

        f_output.write(formatted_line + '\n')  # 每行末尾添加换行符

input_file = 'test1.hex'
output_file = 'test2.hex'
format_hex(input_file, output_file)
