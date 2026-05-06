Execution Guide:

sf project deploy start --target-org MyDevOrg

sf apex run --file "scripts/apex/getXeroUrl.apex" --target-org MyRepairOrg

sf apex run --file scripts/apex/checktokens.apex -o MyRepairOrg

sf apex run --file scripts/apex/test-sync.apex -o MyRepairOrg

pmd check
pmd check -d ./force-app/main/default/classes -R ./.ruleset.xml -f text --no-cache
