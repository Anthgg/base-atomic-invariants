with open(r'base-atomic-invariants\contracts\FlashLoanArbitrage.sol', 'r', encoding='utf-8') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if any(k in line for k in ['onMorphoFlashLoan', 'receiveFlashLoan', 'revert', 'require', 'msg.sender']):
        print(f"L{i+1}: {line.strip()}")
