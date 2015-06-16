
local LSTMTDNN = {}


local ok, cunn = pcall(require, 'fbcunn')
if not ok then
    LookupTable = nn.LookupTable
else
    LookupTable = fbcunn.LookupTableGPU
end

function LSTMTDNN.lstmtdnn(word_vocab_size, rnn_size, n, dropout, word_vec_size, char_vec_size, char_vocab_size,
	 		num_feature_maps, kernels, word2char2idx)
    -- input_size = vocab size
    -- rnn_size = dimensionality of hidden layers
    -- n = number of layers
    -- k = word embedding size

    dropout = dropout or 0 

    -- there will be 2*n+1 inputs
    local length = word2char2idx:size(2)
    local word_vec_size = word_vec_size or rnn_size
    local inputs = {}
    table.insert(inputs, nn.Identity()()) -- batch_size x 1 (word indices) 
    table.insert(inputs, nn.Identity()()) -- batch_size x word length (char indices)
    for L = 1,n do
      table.insert(inputs, nn.Identity()()) -- prev_c[L]
      table.insert(inputs, nn.Identity()()) -- prev_h[L]
    end

    local x, input_size_L, word_vec, char_vec, tdnn_output
    local outputs = {}
    for L = 1,n do
	-- c,h from previous timesteps
	local prev_h = inputs[L*2+2]
	local prev_c = inputs[L*2+1]
	-- the input to this layer
	if L == 1 then 
	    char_vec = nn.LookupTable(char_vocab_size, char_vec_size)(inputs[2]) --batch_size * word length * char_vec_size
	    local layer1 = {}
	    for i = 1, #kernels do
		local reduced_l = length - kernels[i] + 1 
		local conv_layer = nn.TemporalConvolution(char_vec_size, num_feature_maps, kernels[i])(char_vec)
		local pool_layer = nn.TemporalMaxPooling(reduced_l)(nn.ReLU()(conv_layer))
		table.insert(layer1, pool_layer)
	    end
	    local layer1_concat = nn.JoinTable(3)(layer1)
	    tdnn_output = nn.Squeeze()(layer1_concat)
	    --tdnn_output = TDNN.tdnn(length, char_vec_size, tdnn_output_size, kernels) -- batch_size * tdnn_output_size  
	    word_vec = LookupTable(word_vocab_size, word_vec_size)(inputs[1])            
	    --x = nn.Identity()(word_vec)
	    x = nn.CAddTable()({nn.Identity()(tdnn_output), word_vec})
	    input_size_L = word_vec_size
	else 
	    x = outputs[(L-1)*2] 
	    if dropout > 0 then x = nn.Dropout(dropout)(x) end -- apply dropout, if any
	    input_size_L = rnn_size
	end
	-- evaluate the input sums at once for efficiency
	local i2h = nn.Linear(input_size_L, 4 * rnn_size)(x)
	local h2h = nn.Linear(rnn_size, 4 * rnn_size)(prev_h)
	local all_input_sums = nn.CAddTable()({i2h, h2h})
	-- decode the gates
	local sigmoid_chunk = nn.Narrow(2, 1, 3 * rnn_size)(all_input_sums)
	sigmoid_chunk = nn.Sigmoid()(sigmoid_chunk)
	local in_gate = nn.Narrow(2, 1, rnn_size)(sigmoid_chunk)
	local forget_gate = nn.Narrow(2, rnn_size + 1, rnn_size)(sigmoid_chunk)
	local out_gate = nn.Narrow(2, 2 * rnn_size + 1, rnn_size)(sigmoid_chunk)
	-- decode the write inputs
	local in_transform = nn.Narrow(2, 3 * rnn_size + 1, rnn_size)(all_input_sums)
	in_transform = nn.Tanh()(in_transform)
	-- perform the LSTM update
	local next_c           = nn.CAddTable()({
	    nn.CMulTable()({forget_gate, prev_c}),
	    nn.CMulTable()({in_gate,     in_transform})
	  })
	-- gated cells form the output
	local next_h = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})

	table.insert(outputs, next_c)
	table.insert(outputs, next_h)
    end

  -- set up the decoder
    local top_h = outputs[#outputs]
    if dropout > 0 then top_h = nn.Dropout(dropout)(top_h) end
    local proj = nn.Linear(rnn_size, word_vocab_size)(top_h)
    local logsoft = nn.LogSoftMax()(proj)
    table.insert(outputs, logsoft)

    return nn.gModule(inputs, outputs)
end

return LSTMTDNN

