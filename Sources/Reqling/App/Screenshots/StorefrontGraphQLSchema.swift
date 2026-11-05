#if DEBUG
/// The schema behind screenshot mode's GraphQL request, written into the Storefront project as a schema file, since
/// screenshot mode never introspects.
enum StorefrontGraphQLSchema {
    static let fileName = "storefront.graphql"

    static let sdl = #"""
        "The storefront's entry points."
        type Query {
          "Products whose title or tags match, best match first."
          search(query: String!, first: Int = 10, sort: ProductSort = RELEVANCE): ProductConnection!
          product(handle: String!): Product
          collections(first: Int = 10): [Collection!]!
        }

        type Mutation {
          addToCart(productId: ID!, quantity: Int! = 1): Cart!
        }

        interface Node {
          id: ID!
        }

        "Something for sale, in one or more variants."
        type Product implements Node {
          id: ID!
          "The URL-safe name, unique in the store."
          handle: String!
          title: String!
          description: String
          priceRange: PriceRange!
          price: Money @deprecated(reason: "Use priceRange.")
          variants(first: Int = 10): [ProductVariant!]!
          tags: [String!]!
          availableForSale: Boolean!
        }

        type ProductVariant implements Node {
          id: ID!
          title: String!
          price: Money!
          availableForSale: Boolean!
        }

        type ProductConnection {
          nodes: [Product!]!
          totalCount: Int!
        }

        type Collection implements Node {
          id: ID!
          title: String!
          products(first: Int = 10): ProductConnection!
        }

        type PriceRange {
          min: Money!
          max: Money!
        }

        type Money {
          amount: String!
          currencyCode: CurrencyCode!
        }

        type Cart {
          id: ID!
          lines: [CartLine!]!
          total: Money!
        }

        type CartLine {
          product: Product!
          quantity: Int!
        }

        enum CurrencyCode {
          USD
          EUR
          GBP
        }

        enum ProductSort {
          RELEVANCE
          PRICE_ASC
          PRICE_DESC
          NEWEST
        }
        """#
}
#endif
