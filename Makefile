echidna, e: 
	rm -rf crytic-export
	forge clean
	echidna contracts/fuzz/FuzzDeployments.sol --contract FuzzDeployments --config contracts/fuzz/echidna.yaml

launch, l: 
	eval $(op signin)
	cloudexec launch --size c-8

check, c: 
	eval $(op signin)
	cloudexec status 