import Foundation

struct DiscourseCategoryList: Decodable {
    let categoryList: CategoryList

    enum CodingKeys: String, CodingKey {
        case categoryList = "category_list"
    }

    struct CategoryList: Decodable {
        let categories: [DiscourseCategory]
    }
}

struct DiscourseCategory: Decodable, Identifiable {
    let id: Int
    let name: String
    let color: String
    let textColor: String?
    let slug: String
    let topicCount: Int
    let description: String?
    let descriptionExcerpt: String?
    let parentCategoryId: Int?
    /// All direct child IDs visible to the current user. Discourse includes
    /// this even when lazy loading only embeds the first few child objects.
    let subcategoryIds: [Int]?
    let subcategoryList: [DiscourseCategory]?

    enum CodingKeys: String, CodingKey {
        case id, name, color, slug, description
        case textColor = "text_color"
        case topicCount = "topic_count"
        case descriptionExcerpt = "description_excerpt"
        case parentCategoryId = "parent_category_id"
        case subcategoryIds = "subcategory_ids"
        case subcategoryList = "subcategory_list"
    }

    init(
        id: Int,
        name: String,
        slug: String,
        color: String = "808080",
        parentCategoryId: Int? = nil,
        subcategoryIds: [Int]? = nil,
        subcategoryList: [DiscourseCategory]? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.textColor = nil
        self.slug = slug
        self.topicCount = 0
        self.description = nil
        self.descriptionExcerpt = nil
        self.parentCategoryId = parentCategoryId
        self.subcategoryIds = subcategoryIds
        self.subcategoryList = subcategoryList
    }

    /// Returns the same server category with a normalized child tree. Keeping
    /// this copy operation in the model avoids teaching every consumer about
    /// Discourse's lazy-load flat response shape.
    func replacingSubcategoryList(_ subcategories: [DiscourseCategory]?) -> DiscourseCategory {
        DiscourseCategory(
            id: id,
            name: name,
            color: color,
            textColor: textColor,
            slug: slug,
            topicCount: topicCount,
            description: description,
            descriptionExcerpt: descriptionExcerpt,
            parentCategoryId: parentCategoryId,
            subcategoryIds: subcategoryIds,
            subcategoryList: subcategories
        )
    }

    private init(
        id: Int,
        name: String,
        color: String,
        textColor: String?,
        slug: String,
        topicCount: Int,
        description: String?,
        descriptionExcerpt: String?,
        parentCategoryId: Int?,
        subcategoryIds: [Int]?,
        subcategoryList: [DiscourseCategory]?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.textColor = textColor
        self.slug = slug
        self.topicCount = topicCount
        self.description = description
        self.descriptionExcerpt = descriptionExcerpt
        self.parentCategoryId = parentCategoryId
        self.subcategoryIds = subcategoryIds
        self.subcategoryList = subcategoryList
    }
}
