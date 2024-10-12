use core::starknet::ContractAddress;

#[starknet::interface]
pub trait IW3ABadges<TContractState> {
    fn get_dropped(self: @TContractState, receiver: ContractAddress) -> bool;
    fn get_badges(self: @TContractState) -> u256;
    fn mint_badge(ref self: TContractState, to: ContractAddress);
    fn modify_white_list(ref self: TContractState, whitelist_addr: ContractAddress, status: bool);
}

#[starknet::contract]
mod W3ABadges {
    use starknet::storage::StorageMapReadAccess;
    use starknet::event::EventEmitter;
    use starknet::storage::StorageMapWriteAccess;
    use core::starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess
    };
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc721::ERC721Component;
    use openzeppelin::token::erc721::ERC721HooksEmptyImpl;
    use openzeppelin::token::erc721::interface::ERC721ABI;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use starknet::{ClassHash, ContractAddress, get_caller_address};

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;

    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,

        // User Address -> Minted/Not Minted
        dropped: Map::<ContractAddress, bool>,
        // mapping to keep track of which addresses are allowed to transfer NFT's
        whitelist: Map::<ContractAddress, bool>,
        token_id_tracker: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Dropped {
        #[key]
        receiver: ContractAddress,
        token_id: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,

        Dropped: Dropped,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        let badge_base_uris: ByteArray = "";
        self.erc721.initializer("Web3Arabs Badges", "W3ABADGES", badge_base_uris.clone());
        self.ownable.initializer(owner);
        self.whitelist.write(owner, true);
    }

    // Public functions inside an impl block
    #[abi(embed_v0)]
    impl W3ABadgesImpl of super::IW3ABadges<ContractState> {
        fn get_dropped(self: @ContractState, receiver: ContractAddress) -> bool {
            self.dropped.entry(receiver).read()
        }

        fn get_badges(self: @ContractState) -> u256 {
            self.token_id_tracker.read()
        }

        fn mint_badge(ref self: ContractState, to: ContractAddress) {
            self.ownable.assert_only_owner();
            let dropped: bool = self.get_dropped(to);
            assert(!dropped, 'ALREADY_DROPPED');

            self.dropped.write(to, true);
            let token_id_trackers = self.token_id_tracker.read();
            self.token_id_tracker.write(token_id_trackers + 1);

            let data: Span<felt252> = ArrayTrait::new().span();
            self.safe_mint(to, token_id_trackers, data);

            self.emit(Dropped { receiver: to, token_id: token_id_trackers });
        }

        fn modify_white_list(ref self: ContractState, whitelist_addr: ContractAddress, status: bool) {
            self.ownable.assert_only_owner();
            self.whitelist.write(whitelist_addr, status);
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl ERC721MixinImpl of ERC721ABI<ContractState> {
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.erc721.balance_of(account)
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.erc721.owner_of(token_id)
        }

        fn safe_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            data: Span<felt252>
        ) {
            let caller = get_caller_address();
            let whitelist: bool = self.whitelist.read(caller);
            assert(whitelist, 'NOT_AUTH');
            self.erc721.safe_transfer_from(from, to, token_id, data);
        }

        fn transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256
        ) {
            let caller = get_caller_address();
            let whitelist: bool = self.whitelist.read(caller);
            assert(whitelist, 'NOT_AUTH');
            self.erc721.transfer_from(from, to, token_id);
        }

        fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            self.erc721.approve(to, token_id);
        }

        fn set_approval_for_all(
            ref self: ContractState, operator: ContractAddress, approved: bool
        ) {
            self.erc721.set_approval_for_all(operator, approved);
        }

        fn get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            self.erc721.get_approved(token_id)
        }

        fn is_approved_for_all(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self.erc721.is_approved_for_all(owner, operator)
        }

        fn name(self: @ContractState) -> ByteArray {
            self.erc721.name()
        }

        fn symbol(self: @ContractState) -> ByteArray {
            self.erc721.symbol()
        }

        fn token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            self.erc721.token_uri(token_id)
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.erc721.balanceOf(account)
        }

        fn ownerOf(self: @ContractState, tokenId: u256) -> ContractAddress {
            self.erc721.ownerOf(tokenId)
        }

        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenId: u256,
            data: Span<felt252>
        ) {
            self.safe_transfer_from(from, to, tokenId, data);
        }

        fn transferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenId: u256
        ) {
            self.transfer_from(from, to, tokenId);
        }

        fn setApprovalForAll(
            ref self: ContractState, operator: ContractAddress, approved: bool
        ) {
            self.erc721.setApprovalForAll(operator, approved);
        }

        fn getApproved(self: @ContractState, tokenId: u256) -> ContractAddress {
            self.erc721.getApproved(tokenId)
        }

        fn isApprovedForAll(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self.erc721.isApprovedForAll(owner, operator)
        }

        fn tokenURI(self: @ContractState, tokenId: u256) -> ByteArray {
            self.erc721.tokenURI(tokenId)
        }

        // ISRC5
        fn supports_interface(
            self: @ContractState, interface_id: felt252
        ) -> bool {
            self.erc721.supports_interface(interface_id)
        }
    }

    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn safe_mint(
            ref self: ContractState,
            recipient: ContractAddress,
            token_id: u256,
            data: Span<felt252>,
        ) {
            self.ownable.assert_only_owner();
            self.erc721.safe_mint(recipient, token_id, data);
        }

        #[external(v0)]
        fn safeMint(
            ref self: ContractState,
            recipient: ContractAddress,
            tokenId: u256,
            data: Span<felt252>,
        ) {
            self.safe_mint(recipient, tokenId, data);
        }

        #[external(v0)]
        fn set_base_uri(
            ref self: ContractState,
            base_uri: ByteArray
        ) {
            self.ownable.assert_only_owner();
            self.erc721._set_base_uri(base_uri);
        }

        #[external(v0)]
        fn setBaseUri(
            ref self: ContractState,
            base_uri: ByteArray
        ) {
            self.set_base_uri(base_uri);
        }
    }
}
