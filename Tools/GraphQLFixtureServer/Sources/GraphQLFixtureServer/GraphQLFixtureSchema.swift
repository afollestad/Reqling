import GraphQL

/// The schema the fixture server answers from, and the mock data it resolves.
///
/// It is written to exercise every corner of introspection and of query analysis rather than to model a real API:
/// renamed root types, interfaces implementing interfaces, a union, deprecated fields, arguments, input fields and enum
/// values, `@specifiedBy`, `@oneOf`, a repeatable directive, nested input defaults, a five-deep wrapped type,
/// keyword-named fields, and descriptions with emoji and several lines. Tests that assert on it name the elements they
/// rely on, so add to it rather than renaming.
///
/// It is a Swift string, not a resource: `scripts/build.sh` copies every bundle in the root's build folder into the app.
public enum GraphQLFixtureSchema {
    public static let sdl = #"""
        """
        A small library API 📚, written to exercise introspection and query analysis.
        Its second line mentions a café.
        """
        schema {
          query: Root
          mutation: Mutations
          subscription: Events
        }

        "An ISO 8601 date and time."
        scalar DateTime @specifiedBy(url: "https://scalars.graphql.org/andimarek/date-time")

        "Any JSON value."
        scalar JSON

        "How long a field's value may be cached."
        directive @cacheControl(maxAge: Int = 60, scope: CacheScope = PUBLIC) on FIELD_DEFINITION | OBJECT

        "Tags a selection for logging; may repeat."
        directive @tag(name: String!) repeatable on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT | QUERY | VARIABLE_DEFINITION

        enum CacheScope {
          PUBLIC
          PRIVATE
        }

        "Anything with a global ID."
        interface Node {
          id: ID!
        }

        "A stored record."
        interface Entity implements Node {
          id: ID!
          createdAt: DateTime!
        }

        "A person who writes books."
        type Author implements Entity & Node {
          id: ID!
          createdAt: DateTime!
          name: String!
          """
          The author's books, newest first.

          Pages hold at most 100.
          """
          books(first: Int = 10, after: String, orderBy: BookOrder = {field: TITLE, direction: DESC}): [Book!]!
          nickname: String @deprecated(reason: "Use `name`.")
        }

        "A book in the catalog."
        type Book implements Entity & Node @cacheControl(maxAge: 300) {
          id: ID!
          createdAt: DateTime!
          title: String!
          isbn: String
          genre: Genre
          author: Author!
          "Shelf labels, grouped by shelf."
          shelves: [[String!]!]!
          ratings: [Int]
          on: Boolean
          type: String
          fragment: String
          metadata: JSON
        }

        enum Genre {
          FICTION
          NON_FICTION
          "Poems and verse."
          POETRY
          SCIENCE_FICTION @deprecated(reason: "Use `FICTION` with a tag.")
        }

        enum BookField {
          TITLE
          CREATED_AT
        }

        enum Direction {
          ASC
          DESC
        }

        input BookOrder {
          field: BookField!
          direction: Direction = ASC
        }

        input BookFilter {
          genre: Genre
          titleContains: String
          publishedAfter: DateTime
          authorIDs: [ID!]
          and: [BookFilter!]
          legacyCode: String @deprecated(reason: "No longer read.")
        }

        "Exactly one way to find a book."
        input BookLookup @oneOf {
          id: ID
          isbn: String
        }

        input NewBook {
          title: String!
          authorID: ID!
          genre: Genre = FICTION
          tags: [String!] = ["new"]
        }

        union SearchResult = Book | Author

        type Root {
          node(id: ID!): Node
          book(lookup: BookLookup!): Book
          books(
            filter: BookFilter
            order: BookOrder
            first: Int = 20
            legacyPage: Int @deprecated(reason: "Use `first`.")
          ): [Book!]!
          authors: [Author!]!
          search(text: String!, limit: Int = 5): [SearchResult!]!
          me: Author
          ping: String!
        }

        type Mutations {
          addBook(input: NewBook!): Book!
          removeBook(id: ID!): Boolean!
        }

        type Events {
          bookAdded(genre: Genre): Book!
        }
        """#

    /// What queries resolve against. Values are built lazily, so cycles (`book.author.books`) cost nothing until asked
    /// for. Arguments are ignored, and fields typed as an interface or union resolve to `null` or `[]`: a schema built
    /// from SDL has no way to tell which object type a value is.
    public static var rootValue: any Sendable {
        MockObject { field in
            switch field {
            case "ping": "pong"
            case "me": author
            case "authors": [author]
            case "books": [book]
            case "book": book
            case "search": [any Sendable]()
            case "addBook": book
            case "removeBook": true
            default: nil
            }
        }
    }

    private static var author: MockObject {
        MockObject { field in
            switch field {
            case "id": "author-1"
            case "createdAt": "2024-05-01T09:30:00Z"
            case "name": "Ursula K. Le Guin"
            case "nickname": "UKL"
            case "books": [book]
            default: nil
            }
        }
    }

    private static var book: MockObject {
        MockObject { field in
            switch field {
            case "id": "book-1"
            case "createdAt": "2024-05-02T10:00:00Z"
            case "title": "The Dispossessed"
            case "isbn": "978-0-06-051275-0"
            case "genre": "FICTION"
            case "author": author
            case "shelves": [["Fiction", "Classics"]]
            case "ratings": [5, 4]
            default: nil
            }
        }
    }
}

/// An object the default resolver reads field by field.
private struct MockObject: KeySubscriptable, Sendable {
    let resolve: @Sendable (String) -> (any Sendable)?

    subscript(field: String) -> (any Sendable)? {
        resolve(field)
    }
}
